import Foundation
import NetworkExtension
import OpenVPNCore

/// The packet tunnel extension: owns the utun interface and runs the
/// from-scratch OpenVPN client.
///
/// Routing safety:
/// - Native per-app mode: macOS scopes this packet tunnel to the selected
///   `NEAppRule`s. The provider can therefore install the default route
///   inside that system scope, without capturing other apps.
/// - Full-tunnel mode: the utun becomes the default route for the system and
///   the server-pushed DNS servers are applied.
class TunnelProvider: NEPacketTunnelProvider, OpenVPNConnection.Delegate {
    private var connection: OpenVPNConnection?
    private var physicalInterface: String?
    private var startCompletionHandler: ((Error?) -> Void)?
    private var tunnelSettingsGeneration: UInt64 = 0
    private var readingPackets = false
    private var sentPacketCount: UInt64 = 0
    private var receivedPacketCount: UInt64 = 0
    private var logFile: FileHandle?
    /// Serializes log writes: delegate callbacks arrive on the connection's
    /// queue while provider callbacks come from the extension's queue.
    private let logQueue = DispatchQueue(label: "com.semivpn.tunnel.log")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setupLogging()
        startCompletionHandler = completionHandler
        log("startTunnel")

        guard let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let profileText = config[SharedConfig.profileKey] as? String, !profileText.isEmpty else {
            finishStart(with: tunnelError("No profile provided", code: 1))
            return
        }

        let profile: OVPNProfile
        do {
            profile = try OVPNParser().parse(profileText)
        } catch {
            finishStart(with: tunnelError("Invalid profile: \(error)", code: 2))
            return
        }
        physicalInterface = Self.defaultPhysicalInterface()
        log("physical interface: \(physicalInterface ?? "nil")")

        let connection = OpenVPNConnection(profile: profile)
        connection.delegate = self
        connection.bindInterfaceName = self.physicalInterface
        self.connection = connection
        connection.connect()
        self.readPackets()
        // Tunnel settings are applied when the PUSH_REPLY arrives (state
        // .ready). Do not report success until the OpenVPN data channel and
        // the utun settings are actually ready; otherwise NetworkExtension
        // can show Connected while the handshake is still in progress.
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("stopTunnel: \(reason.rawValue)")
        reasserting = false
        tunnelSettingsGeneration &+= 1
        let oldConnection = connection
        connection = nil
        oldConnection?.delegate = nil
        oldConnection?.disconnect()
        finishStart(with: tunnelError("Tunnel stopped before OpenVPN became ready", code: 3))
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        log("sleep: keeping provider alive for wake recovery")
        // `disconnectOnSleep` is false so the provider receives wake(). Keep
        // the user-visible session in reasserting state until a fresh
        // transport and OpenVPN session are established after wake.
        reasserting = true
        tunnelSettingsGeneration &+= 1
        completionHandler()
    }

    override func wake() {
        log("wake: rebuilding OpenVPN transport")
        guard let connection else {
            log("wake: no active OpenVPN connection")
            return
        }

        reasserting = true
        tunnelSettingsGeneration &+= 1
        // Wi-Fi or the default physical interface may have changed while the
        // Mac slept. Preserve the previous interface only if the system has
        // not published a replacement yet; the core will retry while the
        // network finishes coming back.
        let currentInterface = Self.defaultPhysicalInterface() ?? physicalInterface
        physicalInterface = currentInterface
        connection.reconnectForNetworkChange(bindInterfaceName: currentInterface)
    }

    // MARK: - utun packet flow

    private func readPackets() {
        guard !readingPackets else { return }
        readingPackets = true
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.readingPackets = false
            guard let connection = self.connection else { return }
            for packet in packets {
                self.sentPacketCount &+= 1
                if self.sentPacketCount == 1 || self.sentPacketCount % 100 == 0 {
                    self.log("tunnel outbound: packet #\(self.sentPacketCount) (\(packet.count) bytes)")
                }
                connection.sendIPPacket(packet)
            }
            self.readPackets()
        }
    }

    func connection(_ connection: OpenVPNConnection, didReceiveIPPacket packet: Data) {
        receivedPacketCount &+= 1
        if receivedPacketCount == 1 || receivedPacketCount % 100 == 0 {
            log("tunnel inbound: packet #\(receivedPacketCount) (\(packet.count) bytes)")
        }
        let isIPv6 = packet.count > 0 && (packet[0] >> 4) == 6
        let proto = NSNumber(value: isIPv6 ? AF_INET6 : AF_INET)
        packetFlow.writePackets([packet], withProtocols: [proto])
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let localIP = connection?.pushedOptions?.ifconfigLocal ?? ""
        let ifaceName = Self.findTunnelInterfaceName(forIP: localIP) ?? ""
        let info: [String: String] = [
            "interface": ifaceName,
            "ip": localIP,
            "gateway": connection?.pushedOptions?.routeGateway ?? ""
        ]
        completionHandler?(try? JSONSerialization.data(withJSONObject: info))
    }

    private static func findTunnelInterfaceName(forIP targetIP: String) -> String? {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("utun"), let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostBuffer)
                if !targetIP.isEmpty && ip == targetIP {
                    return name
                }
            }
            cursor = current.pointee.ifa_next
        }
        return nil
    }

    // MARK: - Connection delegate

    func connection(_ connection: OpenVPNConnection, stateChanged state: OpenVPNConnection.State) {
        log("state: \(state)")
        switch state {
        case .ready:
            tunnelSettingsGeneration &+= 1
            let generation = tunnelSettingsGeneration
            applyTunnelSettings(connection: connection) { [weak self] error in
                guard let self,
                      self.connection === connection,
                      self.tunnelSettingsGeneration == generation else { return }
                if let error {
                    self.reasserting = false
                    if self.startCompletionHandler != nil {
                        self.finishStart(with: error)
                    } else {
                        self.cancelTunnelWithError(error)
                    }
                    return
                }
                self.reasserting = false
                self.finishStart(with: nil)
            }
        case .reconnecting:
            // NETunnelProvider.reasserting is the supported bridge from the
            // provider's internal reconnect state to NEVPNStatus.reasserting.
            tunnelSettingsGeneration &+= 1
            reasserting = true
        case .failed(let reason):
            tunnelSettingsGeneration &+= 1
            let error = tunnelError("OpenVPN failed: \(reason)", code: 4)
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

    /// Installs the utun address every time a session becomes ready.
    ///
    /// Reapplying on each session matters: the connection now transparently
    /// reconnects (renegotiation, packet-id renewal, server loss), and a
    /// new session can be assigned a different tunnel address.
    ///
    /// In native per-app mode macOS scopes these settings to the matching app
    /// rules. The default route is required so all destinations from a
    /// selected app enter the packet tunnel.
    private func applyTunnelSettings(connection: OpenVPNConnection,
                                     completion: ((Error?) -> Void)? = nil) {
        guard let pushed = connection.pushedOptions else {
            let error = tunnelError("OpenVPN became ready without pushed network settings", code: 6)
            log("tunnel settings error: \(error)")
            completion?(error)
            return
        }

        let local = pushed.ifconfigLocal ?? "10.8.0.2"
        let remote = pushed.routeGateway ?? pushed.ifconfigRemote ?? "10.8.0.1"
        let netmask = pushed.ifconfigRemote ?? "255.255.255.0"
        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let serverAddress = (protocolConfiguration as? NETunnelProviderProtocol)?.serverAddress ?? remote
        let fullTunnel = providerConfiguration[SharedConfig.fullTunnelKey] as? Bool ?? false
        let nativePerApp = providerConfiguration[SharedConfig.nativePerAppKey] as? Bool ?? false
        let scopedRouting = fullTunnel || nativePerApp
        log("applying tunnel settings: local=\(local) remote=\(remote) netmask=\(netmask) server=\(serverAddress) fullTunnel=\(fullTunnel) nativePerApp=\(nativePerApp)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverAddress)
        let ipv4 = NEIPv4Settings(addresses: [local], subnetMasks: [netmask])
        if !scopedRouting {
            ipv4.router = remote
        }
        if scopedRouting {
            // Route all IPv4 traffic through the tunnel EXCEPT 127.0.0.0/8 (loopback).
            // macOS NetworkExtension forbids destinationAddress="127.x.x.x" in excludedRoutes,
            // so loopback exclusion is achieved by including all IPv4 blocks around 127.0.0.0/8.
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
            ipv4.includedRoutes = routeBlocks.map { dest, mask in
                let route = NEIPv4Route(destinationAddress: dest, subnetMask: mask)
                route.gatewayAddress = remote
                return route
            }
            settings.dnsSettings = NEDNSSettings(
                servers: pushed.dnsServers.isEmpty ? ["1.1.1.1"] : pushed.dnsServers
            )
        }
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.log("tunnel settings error: \(error)")
            } else {
                self?.log("tunnel settings applied")
            }
            completion?(error)
        }
    }

    func connection(_ connection: OpenVPNConnection, log message: String) {
        self.log(message)
    }

    // MARK: - Logging

    private func setupLogging() {
        guard let url = SharedConfig.containerURL else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let logURL = url.appendingPathComponent("tunnel.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFile = FileHandle(forWritingAtPath: logURL.path)
    }

    private func log(_ message: String) {
        let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
        logQueue.async { [weak self] in
            self?.logFile?.seekToEndOfFile()
            self?.logFile?.write(Data(line.utf8))
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

    private static func defaultPhysicalInterface() -> String? {
        var address: UnsafeMutablePointer<ifaddrs>?
        var name: String?
        if getifaddrs(&address) == 0 {
            var cursor = address
            while let current = cursor {
                let flags = Int32(current.pointee.ifa_flags)
                let family = current.pointee.ifa_addr.pointee.sa_family
                if family == UInt8(AF_INET), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                    name = String(cString: current.pointee.ifa_name)
                    break
                }
                cursor = current.pointee.ifa_next
            }
            freeifaddrs(address)
        }
        return name
    }
}
