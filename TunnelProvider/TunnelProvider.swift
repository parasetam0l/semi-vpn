import Foundation
import Network
import NetworkExtension
import OpenVPNCore

/// The packet tunnel extension: owns the utun interface and runs the
/// from-scratch OpenVPN client.
///
/// Routing:
/// - Native per-app mode: macOS scopes this packet tunnel to the selected
///   `NEAppRule`s. The provider installs default routes inside that system
///   scope, without capturing other apps.
/// - All-apps mode: follows the server like OpenVPN does. A server that
///   redirects the gateway (or pushes no routes) gets the default route;
///   a split-tunnel server only gets its pushed routes. `net_gateway`
///   routes are excluded in both cases.
///
/// Threading: provider state is confined to `queue`. NetworkExtension
/// callbacks, OpenVPN delegate callbacks and packet-flow completions all
/// hop onto it.
class TunnelProvider: NEPacketTunnelProvider, OpenVPNConnection.Delegate {
    private let queue = DispatchQueue(label: "com.semivpn.tunnel.provider")
    private var connection: OpenVPNConnection?
    private var physicalInterface: String?
    private var startCompletionHandler: ((Error?) -> Void)?
    private var tunnelSettingsGeneration: UInt64 = 0
    private var readingPackets = false
    private var sentPacketCount: UInt64 = 0
    private var receivedPacketCount: UInt64 = 0
    private var pathMonitor: NWPathMonitor?
    private var networkChangeWork: DispatchWorkItem?
    private var logFile: FileHandle?
    /// Serializes log writes from every queue.
    private let logQueue = DispatchQueue(label: "com.semivpn.tunnel.log")

    /// Decrypted packets waiting to be written to the utun in one batch.
    private let inboundLock = NSLock()
    private var inboundPackets: [Data] = []
    private var inboundProtocols: [NSNumber] = []
    private var inboundFlushScheduled = false

    static let maxLogSize: UInt64 = 2 * 1024 * 1024

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setupLogging()
        log("startTunnel")
        queue.async { [self] in
            startCompletionHandler = completionHandler

            let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
            guard let profileText = TunnelSecrets.profileText(from: providerConfiguration), !profileText.isEmpty else {
                finishStart(with: tunnelError("No profile provided", code: 1))
                return
            }

            var profile: OVPNProfile
            do {
                profile = try OVPNParser().parse(profileText)
            } catch {
                finishStart(with: tunnelError("Invalid profile: \(error)", code: 2))
                return
            }
            let credentials = TunnelSecrets.credentials(from: providerConfiguration)
            if let username = credentials.username, !username.isEmpty {
                profile.authUserPass = OVPNProfile.AuthUserPass(username: username, password: credentials.password ?? "")
            }
            if let passphrase = credentials.keyPassphrase, !passphrase.isEmpty {
                profile.keyPassphrase = passphrase
            }
            if let issue = profile.fatalIssues.first {
                finishStart(with: tunnelError("Invalid profile: \(issue.message)", code: 2))
                return
            }

            let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
            monitor.pathUpdateHandler = { [weak self] path in
                self?.handlePathUpdate(path)   // delivered on `queue`
            }
            monitor.start(queue: queue)
            pathMonitor = monitor
            physicalInterface = Self.physicalInterfaceName(for: monitor.currentPath) ?? Self.fallbackPhysicalInterface()
            log("physical interface: \(physicalInterface ?? "nil")")

            let connection = OpenVPNConnection(profile: profile)
            connection.delegate = self
            connection.bindInterfaceName = physicalInterface
            self.connection = connection
            connection.connect()
            readPackets()
            // Tunnel settings are applied when the PUSH_REPLY arrives (state
            // .ready). Success is not reported until the OpenVPN data channel
            // and the utun settings are actually ready; otherwise
            // NetworkExtension can show Connected while the handshake is
            // still in progress.
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("stopTunnel: \(reason.rawValue)")
        queue.async { [self] in
            reasserting = false
            tunnelSettingsGeneration &+= 1
            pathMonitor?.cancel()
            pathMonitor = nil
            networkChangeWork?.cancel()
            let oldConnection = connection
            connection = nil
            oldConnection?.delegate = nil
            finishStart(with: tunnelError("Tunnel stopped before OpenVPN became ready", code: 3))
            guard let oldConnection else {
                completionHandler()
                return
            }
            // Give the server its exit notification, but never hold up the
            // system for long.
            let done = OnceFlag()
            oldConnection.disconnect {
                if done.set() { completionHandler() }
            }
            queue.asyncAfter(deadline: .now() + 1.0) {
                if done.set() { completionHandler() }
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        log("sleep: keeping provider alive for wake recovery")
        queue.async { [self] in
            // `disconnectOnSleep` is false so the provider receives wake().
            // Keep the user-visible session in reasserting state until a
            // fresh transport and OpenVPN session are established after wake.
            reasserting = true
            tunnelSettingsGeneration &+= 1
            completionHandler()
        }
    }

    override func wake() {
        log("wake: rebuilding OpenVPN transport")
        queue.async { [self] in
            guard let connection else {
                log("wake: no active OpenVPN connection")
                return
            }
            reasserting = true
            tunnelSettingsGeneration &+= 1
            // NAT mappings and Wi-Fi associations rarely survive sleep:
            // always start over on the current physical interface.
            let currentInterface = pathMonitor.flatMap { Self.physicalInterfaceName(for: $0.currentPath) }
                ?? physicalInterface
            physicalInterface = currentInterface
            connection.reconnectForNetworkChange(bindInterfaceName: currentInterface)
        }
    }

    // MARK: - Network changes

    /// Rebinds the transport when the physical network changes while awake
    /// (Wi-Fi to Ethernet, a new Wi-Fi network): the old socket stays bound
    /// to an interface that no longer carries traffic.
    private func handlePathUpdate(_ path: Network.NWPath) {
        guard connection != nil else { return }
        guard path.status == .satisfied, let interface = Self.physicalInterfaceName(for: path) else {
            log("network path: \(path.status) (waiting for a usable interface)")
            return
        }
        guard interface != physicalInterface else { return }
        log("network path: physical interface \(physicalInterface ?? "nil") -> \(interface)")
        physicalInterface = interface
        // Interface changes come in bursts; reconnect once things settle.
        networkChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let connection = self.connection else { return }
            self.reasserting = true
            connection.reconnectForNetworkChange(bindInterfaceName: self.physicalInterface)
        }
        networkChangeWork = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// The preferred physical interface of a path, excluding tunnels.
    static func physicalInterfaceName(for path: Network.NWPath) -> String? {
        let preferred: [NWInterface.InterfaceType] = [.wiredEthernet, .wifi, .cellular]
        let candidates = path.availableInterfaces.filter { preferred.contains($0.type) }
        return candidates.first?.name
    }

    /// Used before the path monitor delivered its first path: the first
    /// running non-tunnel interface with an IPv4 address.
    private static func fallbackPhysicalInterface() -> String? {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return nil }
        defer { freeifaddrs(first) }
        let virtualPrefixes = ["lo", "utun", "ipsec", "ppp", "gif", "stf", "bridge", "awdl", "llw", "anpi", "ap"]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            if virtualPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            return name
        }
        return nil
    }

    /// The MTU of an interface (1500 when unknown).
    private static func interfaceMTU(_ name: String?) -> Int {
        guard let name else { return 1500 }
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return 1500 }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: current.pointee.ifa_name) == name,
                  let data = current.pointee.ifa_data else { continue }
            let mtu = Int(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
            return mtu > 0 ? mtu : 1500
        }
        return 1500
    }

    // MARK: - utun packet flow

    private func readPackets() {
        guard !readingPackets else { return }
        readingPackets = true
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.queue.async {
                self.readingPackets = false
                guard let connection = self.connection else { return }
                let hasVPNIPv6 = connection.hasVPNIPv6
                var outbound: [Data] = []
                outbound.reserveCapacity(packets.count)
                var rejections: [Data] = []
                for packet in packets {
                    let isIPv6 = packet.first.map { $0 >> 4 == 6 } ?? false
                    if isIPv6 && !hasVPNIPv6 {
                        // IPv6 Leak Protection: do not forward packet into the
                        // IPv4-only OpenVPN tunnel. Synthesize ICMPv6 Destination
                        // Unreachable so Happy Eyeballs immediately falls back to
                        // IPv4 without waiting for a connection timeout.
                        if let reply = ICMPv6Synthesizer.makeDestinationUnreachable(invokingPacket: packet) {
                            rejections.append(reply)
                        }
                        continue
                    }
                    outbound.append(packet)
                }
                if !rejections.isEmpty {
                    self.packetFlow.writePackets(rejections, withProtocols: rejections.map { _ in NSNumber(value: AF_INET6) })
                }
                if !outbound.isEmpty {
                    let before = self.sentPacketCount
                    self.sentPacketCount &+= UInt64(outbound.count)
                    if before == 0 || before / 1000 != self.sentPacketCount / 1000 {
                        self.log("tunnel outbound: \(self.sentPacketCount) packets")
                    }
                    connection.sendIPPackets(outbound)
                }
                self.readPackets()
            }
        }
    }

    func connection(_ connection: OpenVPNConnection, didReceiveIPPacket packet: Data) {
        // Called on the connection queue for every packet: batch the utun
        // writes instead of one system call per packet.
        let isIPv6 = packet.first.map { $0 >> 4 == 6 } ?? false
        inboundLock.lock()
        inboundPackets.append(packet)
        inboundProtocols.append(NSNumber(value: isIPv6 ? AF_INET6 : AF_INET))
        let schedule = !inboundFlushScheduled
        inboundFlushScheduled = true
        inboundLock.unlock()
        if schedule {
            queue.async { [weak self] in self?.flushInbound() }
        }
    }

    private func flushInbound() {
        inboundLock.lock()
        let packets = inboundPackets
        let protocols = inboundProtocols
        inboundPackets.removeAll(keepingCapacity: true)
        inboundProtocols.removeAll(keepingCapacity: true)
        inboundFlushScheduled = false
        inboundLock.unlock()
        guard !packets.isEmpty else { return }
        let before = receivedPacketCount
        receivedPacketCount &+= UInt64(packets.count)
        if before == 0 || before / 1000 != receivedPacketCount / 1000 {
            log("tunnel inbound: \(receivedPacketCount) packets")
        }
        packetFlow.writePackets(packets, withProtocols: protocols)
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async { [self] in
            let pushed = connection?.pushedOptions
            let localIP = pushed?.ifconfigLocal ?? ""
            let localIPv6 = pushed?.ifconfigIPv6Local ?? connection?.profile.ifconfigIPv6Local ?? ""
            let hasVPNIPv6 = connection?.hasVPNIPv6 ?? false
            let info: [String: String] = [
                "interface": Self.findTunnelInterfaceName(forIP: localIP) ?? "",
                "ip": localIP,
                "ipv6": hasVPNIPv6 ? localIPv6 : ICMPv6Synthesizer.defaultTunnelIPv6,
                "hasVPNIPv6": hasVPNIPv6 ? "true" : "false",
                "gateway": pushed?.ipv4Gateway ?? "",
                "server": connection?.currentRemote?.host ?? "",
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: info))
        }
    }

    private static func findTunnelInterfaceName(forIP targetIP: String) -> String? {
        guard !targetIP.isEmpty else { return nil }
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("utun"), let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) || addr.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            if String(cString: hostBuffer) == targetIP {
                return name
            }
        }
        return nil
    }

    // MARK: - Connection delegate

    func connection(_ connection: OpenVPNConnection, stateChanged state: OpenVPNConnection.State) {
        log("state: \(state)")
        queue.async { [self] in
            guard self.connection === connection else { return }
            switch state {
            case .ready:
                tunnelSettingsGeneration &+= 1
                let generation = tunnelSettingsGeneration
                applyTunnelSettings(connection: connection) { [weak self] error in
                    self?.queue.async {
                        guard let self,
                              self.connection === connection,
                              self.tunnelSettingsGeneration == generation else { return }
                        self.reasserting = false
                        if let error {
                            if self.startCompletionHandler != nil {
                                self.finishStart(with: error)
                            } else {
                                self.cancelTunnelWithError(error)
                            }
                            return
                        }
                        self.finishStart(with: nil)
                    }
                }
            case .reconnecting:
                // NETunnelProvider.reasserting is the supported bridge from the
                // provider's internal reconnect state to NEVPNStatus.reasserting.
                tunnelSettingsGeneration &+= 1
                reasserting = true
            case .failed(let reason):
                tunnelSettingsGeneration &+= 1
                let error = tunnelError(reason, code: 4)
                reasserting = false
                if startCompletionHandler != nil {
                    finishStart(with: error)
                } else {
                    cancelTunnelWithError(error)
                }
            case .disconnected:
                tunnelSettingsGeneration &+= 1
                let error = tunnelError("OpenVPN disconnected", code: 5)
                reasserting = false
                if startCompletionHandler != nil {
                    finishStart(with: error)
                } else {
                    cancelTunnelWithError(error)
                }
            default:
                break
            }
        }
    }

    /// Installs the utun address, routes, DNS and MTU every time a session
    /// becomes ready: a reconnect can be assigned a different address.
    private func applyTunnelSettings(connection: OpenVPNConnection,
                                     completion: @escaping (Error?) -> Void) {
        guard let pushed = connection.pushedOptions, let local = pushed.ifconfigLocal else {
            let error = tunnelError("OpenVPN became ready without a pushed tunnel address", code: 6)
            log("tunnel settings error: \(error)")
            completion(error)
            return
        }

        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let fullTunnel = providerConfiguration[SharedConfig.fullTunnelKey] as? Bool ?? false
        let nativePerApp = providerConfiguration[SharedConfig.nativePerAppKey] as? Bool ?? false
        // Per-app mode: the system scopes the tunnel to the selected apps,
        // which want all of their traffic in the tunnel. Otherwise follow
        // the server: redirect-gateway (or no routes at all) means the
        // default route, explicit routes mean a split tunnel.
        let includedServerRoutes = pushed.routes.filter { !$0.excluded }
        let capturesAllIPv4 = nativePerApp || pushed.redirectGateway || includedServerRoutes.isEmpty
        let gateway = pushed.ipv4Gateway
        let serverAddress = connection.currentRemote?.host
            ?? (protocolConfiguration as? NETunnelProviderProtocol)?.serverAddress
            ?? "semi-vpn"

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverAddress)
        let ipv4 = NEIPv4Settings(addresses: [local], subnetMasks: [pushed.ipv4SubnetMask])
        if capturesAllIPv4 {
            // All IPv4 except 127.0.0.0/8: NetworkExtension forbids loopback
            // in excludedRoutes, so the default route is built from blocks
            // around it.
            let routeBlocks: [(String, String)] = [
                ("0.0.0.0", "192.0.0.0"),    // 0.0.0.0/2
                ("64.0.0.0", "224.0.0.0"),   // 64.0.0.0/3
                ("96.0.0.0", "240.0.0.0"),   // 96.0.0.0/4
                ("112.0.0.0", "248.0.0.0"),  // 112.0.0.0/5
                ("120.0.0.0", "252.0.0.0"),  // 120.0.0.0/6
                ("124.0.0.0", "254.0.0.0"),  // 124.0.0.0/7
                ("126.0.0.0", "255.0.0.0"),  // 126.0.0.0/8
                ("128.0.0.0", "128.0.0.0"),  // 128.0.0.0/1
            ]
            ipv4.includedRoutes = routeBlocks.map { destination, mask in
                let route = NEIPv4Route(destinationAddress: destination, subnetMask: mask)
                route.gatewayAddress = gateway
                return route
            }
        } else {
            // Split tunnel: only what the server routes into the VPN.
            ipv4.includedRoutes = includedServerRoutes.map { pushedRoute in
                let route = NEIPv4Route(destinationAddress: pushedRoute.network, subnetMask: pushedRoute.netmask)
                route.gatewayAddress = pushedRoute.gateway ?? gateway
                return route
            }
        }
        let excluded = pushed.routes.filter(\.excluded)
        if !excluded.isEmpty {
            ipv4.excludedRoutes = excluded.map { NEIPv4Route(destinationAddress: $0.network, subnetMask: $0.netmask) }
        }
        settings.ipv4Settings = ipv4

        let hasVPNIPv6 = connection.hasVPNIPv6
        let localIPv6 = pushed.ifconfigIPv6Local ?? connection.profile.ifconfigIPv6Local
        let netbitsIPv6 = pushed.ifconfigIPv6Netbits ?? connection.profile.ifconfigIPv6Netbits ?? 64
        let remoteIPv6 = pushed.ifconfigIPv6Remote ?? connection.profile.ifconfigIPv6Remote ?? pushed.routeIPv6Gateway
        let ipv6Routes = pushed.routesIPv6.isEmpty ? connection.profile.routesIPv6 : pushed.routesIPv6

        if hasVPNIPv6, let localIPv6 {
            log("configuring dual-stack IPv6 tunnel: local=\(localIPv6)/\(netbitsIPv6) remote=\(remoteIPv6 ?? "nil")")
            let ipv6 = NEIPv6Settings(addresses: [localIPv6], networkPrefixLengths: [NSNumber(value: netbitsIPv6)])
            if capturesAllIPv4 || pushed.redirectGatewayIPv6 {
                let defaultRoute = NEIPv6Route.default()
                defaultRoute.gatewayAddress = remoteIPv6
                ipv6.includedRoutes = [defaultRoute]
            } else {
                ipv6.includedRoutes = ipv6Routes.map { r in
                    let route = NEIPv6Route(destinationAddress: r.prefix, networkPrefixLength: NSNumber(value: r.netbits))
                    route.gatewayAddress = r.gateway ?? remoteIPv6
                    return route
                }
            }
            settings.ipv6Settings = ipv6
        } else if capturesAllIPv4 {
            // IPv6 Leak Protection: when the server has no IPv6, give the utun
            // a Unique Local Address and capture all IPv6 traffic. readPackets
            // answers it with ICMPv6 Destination Unreachable, so Happy Eyeballs
            // immediately uses IPv4 through the VPN instead of leaking to en0.
            log("configuring IPv6 leak protection: blackhole ULA tunnel with ICMPv6 rejection")
            let leakProtectionIPv6 = NEIPv6Settings(
                addresses: [ICMPv6Synthesizer.defaultTunnelIPv6],
                networkPrefixLengths: [128]
            )
            leakProtectionIPv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = leakProtectionIPv6
        }

        var dnsServers = pushed.dnsServers
        if hasVPNIPv6 {
            dnsServers.append(contentsOf: pushed.dnsIPv6Servers)
        }
        if !dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: dnsServers)
            if !pushed.searchDomains.isEmpty {
                dns.searchDomains = pushed.searchDomains
            }
            if !pushed.dnsResolveDomains.isEmpty {
                // Split DNS: only these domains go to the VPN's servers.
                dns.matchDomains = pushed.dnsResolveDomains
            } else if !capturesAllIPv4 {
                // A split tunnel is not the default route: an empty match
                // domain still makes the VPN's servers the default resolver,
                // as OpenVPN clients do.
                dns.matchDomains = [""]
            }
            settings.dnsSettings = dns
        } else if capturesAllIPv4 {
            // Without pushed DNS the LAN resolver is unreachable through a
            // full tunnel; use a public resolver through the tunnel.
            log("the server pushed no DNS servers: using 1.1.1.1 through the tunnel")
            settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1"])
        }

        let mtu = tunnelMTU(for: connection, pushed: pushed)
        settings.mtu = NSNumber(value: mtu)

        log("applying tunnel settings: local=\(local)/\(pushed.ipv4SubnetMask) gateway=\(gateway ?? "-") " +
            "server=\(serverAddress) routing=\(capturesAllIPv4 ? "all" : "split (\(includedServerRoutes.count) routes)") " +
            "fullTunnel=\(fullTunnel) nativePerApp=\(nativePerApp) dns=\(dnsServers) mtu=\(mtu)")

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.log("tunnel settings error: \(error)")
            } else {
                self?.log("tunnel settings applied")
            }
            completion(error)
        }
    }

    /// The utun MTU: the pushed/profile `tun-mtu`, capped so an encrypted
    /// full-size packet still fits the physical link without IP
    /// fragmentation (which many networks drop). Apps derive their TCP MSS
    /// from it, so this replaces OpenVPN's mssfix.
    private func tunnelMTU(for connection: OpenVPNConnection, pushed: PushedOptions) -> Int {
        let requested = pushed.tunMTU ?? connection.profile.tunMTU ?? 1500
        let remote = connection.currentRemote
        let transport = remote.map { connection.profile.transport(for: $0) } ?? connection.profile.transport
        let outerIP = remote?.family == .ipv6 ? 40 : 20
        let outerTransport = transport == .tcp ? 20 + 2 : 8
        let openvpn: Int
        if connection.negotiatedCipher.isAEAD {
            openvpn = 4 + (pushed.aeadEpoch ? 8 : 4) + 16          // header, packet-id, tag
        } else {
            let hmac: Int
            switch connection.negotiatedDigest {
            case .sha1: hmac = 20
            case .sha256: hmac = 32
            case .sha384: hmac = 48
            case .sha512: hmac = 64
            }
            openvpn = 4 + hmac + 16 + 4 + 16                       // header, HMAC, IV, packet-id, padding
        }
        let linkMTU = Self.interfaceMTU(physicalInterface)
        let fitting = linkMTU - outerIP - outerTransport - openvpn
        return max(1280, min(requested, fitting))
    }

    func connection(_ connection: OpenVPNConnection, log message: String) {
        self.log(message)
    }

    // MARK: - Logging

    private func setupLogging() {
        guard let url = SharedConfig.containerURL else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let logURL = url.appendingPathComponent("tunnel.log")
        // Keep the previous run for diagnostics, but bound the size.
        let previousURL = url.appendingPathComponent("tunnel.previous.log")
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: logURL, to: previousURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFile = FileHandle(forWritingAtPath: logURL.path)
    }

    private func log(_ message: String) {
        let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
        logQueue.async { [weak self] in
            guard let logFile = self?.logFile else { return }
            let size = logFile.seekToEndOfFile()
            if size > Self.maxLogSize {
                logFile.truncateFile(atOffset: 0)
            }
            logFile.write(Data(line.utf8))
        }
    }

    // MARK: - Helpers

    private func finishStart(with error: Error?) {
        guard let handler = startCompletionHandler else { return }
        startCompletionHandler = nil
        handler(error)
    }

    private func tunnelError(_ message: String, code: Int) -> NSError {
        NSError(
            domain: "com.semivpn.tunnel",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// A thread-safe flag that can be set once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns true for the first caller only.
    func set() -> Bool {
        lock.withLock {
            defer { isSet = true }
            return !isSet
        }
    }
}
