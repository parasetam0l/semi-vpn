import Foundation
import NetworkExtension

/// The transparent-proxy extension: sees the system's TCP and UDP flows
/// and decides per app whether they belong in the tunnel.
///
/// - Per-app mode: flows from selected apps are spliced through sockets
///   bound to the tunnel's utun (`IP_BOUND_IF`), so their traffic travels
///   inside the VPN. Every other flow returns NO from `handleNewFlow`,
///   which makes the networking stack carry it directly — untouched.
/// - Full-tunnel mode: the packet tunnel installs the default route and
///   owns all traffic; flows bypass this provider.
///
/// NETransparentProxyProvider is the only macOS provider type that
/// receives all flows without an MDM per-app-VPN payload; a plain
/// NEAppProxyProvider receives none.
class FlowProxyProvider: NETransparentProxyProvider {
    private var selection: SharedConfig.Selection?
    private var logFile: FileHandle?
    private let logQueue = DispatchQueue(label: "com.semivpn.flowproxy.log")

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        setupLogging()
        log("flow-proxy startProxy")
        selection = SharedConfig.Selection.fromProviderConfiguration(
            (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        )
        log("mode: \(selection?.fullTunnel == true ? "full-tunnel" : "per-app"), selected apps: \(selection?.appIdentifiers.count ?? 0)")

        // A transparent proxy receives only traffic covered by its network
        // settings. Capture outbound TCP and UDP here, then return false for
        // apps that are not selected so the system carries those flows
        // directly. Without these rules handleNewFlow is never called.
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(
                remoteNetwork: nil,
                remotePrefix: 0,
                localNetwork: nil,
                localPrefix: 0,
                protocol: .TCP,
                direction: .outbound
            ),
            NENetworkRule(
                remoteNetwork: nil,
                remotePrefix: 0,
                localNetwork: nil,
                localPrefix: 0,
                protocol: .UDP,
                direction: .outbound
            ),
        ]
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.log("transparent proxy settings error: \(error)")
            } else {
                self?.log("transparent proxy settings applied")
            }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("flow-proxy stop: \(reason.rawValue)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let appID = flow.metaData.sourceAppSigningIdentifier
        let isUDP = flow is NEAppProxyUDPFlow

        guard selection?.fullTunnel == true || selection?.appIdentifiers.contains(appID) == true else {
            // NETransparentProxyProvider has special semantics for false:
            // the original flow continues through the normal networking
            // stack. This is the direct path for non-selected apps.
            log("flow from \(appID) (\(isUDP ? "udp" : "tcp")) -> direct")
            return false
        }

        // Fail closed: a tunnel-bound flow with no usable tunnel interface
        // must not silently fall back to the physical network.
        guard let tunnel = Self.tunnelInterfaceName() else {
            log("no tunnel interface for flow from \(appID): terminating flow")
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return true
        }
        log("flow from \(appID) (\(isUDP ? "udp" : "tcp")) -> bind \(tunnel)")

        if let udpFlow = flow as? NEAppProxyUDPFlow {
            UDPFlowProxy.splice(
                udpFlow,
                bindInterface: tunnel,
                log: { [weak self] message in self?.log(message) }
            )
            return true
        }
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            FlowProxy.splice(
                tcpFlow,
                bindInterface: tunnel,
                log: { [weak self] message in self?.log(message) }
            )
            return true
        }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        return false
    }

    // MARK: - Logging

    private func setupLogging() {
        guard let url = SharedConfig.containerURL else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let logURL = url.appendingPathComponent("flowproxy.log")
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

    /// The packet tunnel's utun interface: the newest utun with an IPv4
    /// address (the tunnel provider configures its address on connect).
    private static func tunnelInterfaceName() -> String? {
        var address: UnsafeMutablePointer<ifaddrs>?
        var names: [String] = []
        if getifaddrs(&address) == 0 {
            var cursor = address
            while let current = cursor {
                let name = String(cString: current.pointee.ifa_name)
                let flags = Int32(current.pointee.ifa_flags)
                let family = current.pointee.ifa_addr.pointee.sa_family
                if name.hasPrefix("utun"), family == UInt8(AF_INET), flags & IFF_UP != 0 {
                    names.append(name)
                }
                cursor = current.pointee.ifa_next
            }
            freeifaddrs(address)
        }
        return names.sorted {
            (Int($0.dropFirst(4)) ?? 0) < (Int($1.dropFirst(4)) ?? 0)
        }.last
    }
}
