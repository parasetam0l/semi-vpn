import Foundation
import Network

/// A loopback HTTP proxy for browser domain routing.
///
/// The proxy is deliberately narrow: it supports HTTP requests and HTTPS
/// CONNECT, but only for domains in SharedConfig. It also refuses to forward
/// anything until VPNManager marks the independent browser-domain overlay as
/// connected. Chrome can therefore keep a cached PAC script without turning
/// this into a direct fallback path.
final class LocalProxyServer {
    private let queue = DispatchQueue(label: "com.semivpn.local-proxy", qos: .utility)
    private let stateLock = NSLock()
    private var forwardingAllowed = false
    private var vpnStatus = "disconnected"
    private var proxyListeners: [NWListener] = []
    private var controlListeners: [NWListener] = []
    private var pathMonitor: NWPathMonitor?
    private var lastKnownInterfaces: Set<String>?
    private var restartWorkItem: DispatchWorkItem?

    private static let headerSeparator = Data([13, 10, 13, 10])

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.startPathMonitor()
            self.startListeners()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.stopPathMonitor()
            self.stopListeners()
        }
    }

    func restartListeners() {
        queue.async { [weak self] in
            guard let self else { return }
            self.restartWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                AppLogger.log("local proxy: restarting listeners...")
                self.stopListeners()
                self.queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.startListeners()
                }
            }
            self.restartWorkItem = workItem
            self.queue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let currentInterfaces = Set(path.availableInterfaces.map(\.name))
            if let previous = self.lastKnownInterfaces, previous != currentInterfaces {
                AppLogger.log("local proxy: network interfaces changed: \(previous.sorted().joined(separator: ", ")) -> \(currentInterfaces.sorted().joined(separator: ", "))")
                self.lastKnownInterfaces = currentInterfaces
                self.restartListeners()
            } else if self.lastKnownInterfaces == nil {
                self.lastKnownInterfaces = currentInterfaces
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastKnownInterfaces = nil
    }

    private func startListeners() {
        guard proxyListeners.isEmpty, controlListeners.isEmpty else { return }
        guard let proxyPort = NWEndpoint.Port(rawValue: SharedConfig.localProxyPort),
              let controlPort = NWEndpoint.Port(rawValue: SharedConfig.localControlPort) else {
            AppLogger.log("local proxy: invalid configured port")
            return
        }

        let newProxyListeners = makeLoopbackListeners(on: proxyPort)
        for proxy in newProxyListeners {
            proxy.stateUpdateHandler = { [weak self] state in
                AppLogger.log("local proxy listener: \(Self.listenerStateDescription(state))")
                switch state {
                case .failed, .waiting:
                    self?.retryStartLater()
                default:
                    break
                }
            }
            proxy.newConnectionHandler = { [weak self] connection in
                guard Self.isLocalConnection(connection) else {
                    AppLogger.log("local proxy: rejecting non-local connection from \(connection.endpoint)")
                    connection.cancel()
                    return
                }
                self?.handleProxyConnection(connection)
            }
            proxy.start(queue: queue)
        }
        proxyListeners = newProxyListeners

        let newControlListeners = makeLoopbackListeners(on: controlPort)
        for control in newControlListeners {
            control.stateUpdateHandler = { [weak self] state in
                AppLogger.log("local control listener: \(Self.listenerStateDescription(state))")
                switch state {
                case .failed, .waiting:
                    self?.retryStartLater()
                default:
                    break
                }
            }
            control.newConnectionHandler = { [weak self] connection in
                guard Self.isLocalConnection(connection) else {
                    AppLogger.log("local control: rejecting non-local connection from \(connection.endpoint)")
                    connection.cancel()
                    return
                }
                self?.handleControlConnection(connection)
            }
            control.start(queue: queue)
        }
        controlListeners = newControlListeners

        AppLogger.log("local proxy listening on loopback:\(SharedConfig.localProxyPort) (\(proxyListeners.count) listeners)")
        AppLogger.log("local control API listening on loopback:\(SharedConfig.localControlPort) (\(controlListeners.count) listeners)")
    }

    private func stopListeners() {
        for listener in proxyListeners {
            listener.cancel()
        }
        for listener in controlListeners {
            listener.cancel()
        }
        proxyListeners.removeAll()
        controlListeners.removeAll()
    }

    /// Finds the active point-to-point utun interface assigned an IP address (the SemiVPN tunnel).
    private func findActiveTunnelInterface() -> NWInterface? {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var tunnelNames: [String] = []
        while let current = cursor {
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("utun"), let addr = current.pointee.ifa_addr,
               (addr.pointee.sa_family == UInt8(AF_INET) || addr.pointee.sa_family == UInt8(AF_INET6)) {
                tunnelNames.append(name)
            }
            cursor = current.pointee.ifa_next
        }
        let interfaces = pathMonitor?.currentPath.availableInterfaces ?? []
        return interfaces.first { tunnelNames.contains($0.name) }
    }

    func setForwardingAllowed(_ allowed: Bool) {
        stateLock.lock()
        forwardingAllowed = allowed
        stateLock.unlock()
        AppLogger.log("local proxy forwarding \(allowed ? "enabled" : "disabled")")
    }

    func setVPNStatus(_ status: String) {
        stateLock.lock()
        vpnStatus = status
        stateLock.unlock()
    }

    private func canForward() -> Bool {
        stateLock.lock()
        let inMemory = forwardingAllowed
        stateLock.unlock()
        if inMemory { return true }
        return SharedConfig.loadRuntimeState().forwardingAllowed
    }

    private func currentVPNStatus() -> String {
        stateLock.lock()
        let inMemory = vpnStatus
        stateLock.unlock()
        if inMemory != "disconnected" && inMemory != "invalid" {
            return inMemory
        }
        let runtime = SharedConfig.loadRuntimeState().vpnStatus
        return runtime.isEmpty ? inMemory : runtime
    }

    private func notifyDomainConfigurationChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: SharedConfig.domainConfigurationDidChangeNotification,
                object: nil
            )
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.semivpn.app.domainConfigurationDidChange"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    private func retryStartLater() {
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            AppLogger.log("local proxy: retrying listener start after failure or waiting...")
            self.restartListeners()
        }
    }

    private func makeLoopbackListeners(on port: NWEndpoint.Port) -> [NWListener] {
        var listeners: [NWListener] = []
        // IPv4 loopback (127.0.0.1)
        let p4 = NWParameters.tcp
        p4.allowLocalEndpointReuse = true
        p4.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        if let l4 = try? NWListener(using: p4) {
            listeners.append(l4)
        }
        // IPv6 loopback (::1)
        let p6 = NWParameters.tcp
        p6.allowLocalEndpointReuse = true
        p6.requiredLocalEndpoint = .hostPort(host: .ipv6(.loopback), port: port)
        if let l6 = try? NWListener(using: p6) {
            listeners.append(l6)
        }
        return listeners
    }

    private static func isLocalConnection(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            return addr.rawValue.first == 127
        case .ipv6(let addr):
            if addr == .loopback { return true }
            let bytes = addr.rawValue
            if bytes.count >= 16 && bytes.starts(with: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]) && bytes[12] == 127 {
                return true
            }
            return false
        case .name(let name, _):
            return name == "localhost" || name == "127.0.0.1" || name == "::1"
        @unknown default:
            return false
        }
    }

    // MARK: - Proxy protocol

    private func handleProxyConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection) { [weak self] request in
            guard let self else {
                connection.cancel()
                return
            }
            self.handleProxyRequest(request, client: connection)
        }
    }

    private func handleProxyRequest(_ request: HTTPRequest, client: NWConnection) {
        let target: ProxyTarget?
        if request.method == "CONNECT" {
            target = parseAuthority(request.target, defaultPort: 443)
        } else {
            target = parseHTTPURL(request.target)
        }

        guard let target else {
            sendProxyResponse(status: "400 Bad Request", body: "Invalid target.\n", on: client)
            return
        }

        let domainConfig = SharedConfig.loadDomainConfiguration()
        let isConfigured = SharedConfig.domainMatches(
            host: target.host,
            domains: domainConfig.domains,
            subdomainDomains: domainConfig.subdomainDomains
        )
        guard isConfigured else {
            sendProxyResponse(status: "403 Forbidden", body: "Target is not in SemiVPN's domain list.\n", on: client)
            return
        }

        let isDomainActive = SharedConfig.domainMatches(
            host: target.host,
            domains: domainConfig.activeDomains,
            subdomainDomains: domainConfig.activeSubdomainDomains
        )
        let shouldTunnel = isDomainActive && canForward()

        let upstreamParams = NWParameters.tcp
        upstreamParams.preferNoProxies = true
        if shouldTunnel {
            let hasVPNIPv6 = SharedConfig.loadRuntimeState().hasVPNIPv6
            if !hasVPNIPv6 {
                if let ipOptions = upstreamParams.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                    ipOptions.version = .v4
                }
            }
            // Do not force requiredInterface: NECP policy forbids explicit binding
            // to per-app utun interfaces and will deny the path.
            if let tunnelInterface = findActiveTunnelInterface() {
                AppLogger.log("local proxy: routing \(target.host):\(target.port) (active tunnel: \(tunnelInterface.name))")
            } else {
                AppLogger.log("local proxy: warning: no active tunnel interface found for \(target.host):\(target.port)")
            }
        } else {
            // Fail-open direct routing: when the VPN is disconnected or domain is paused,
            // connect directly over the physical network (dual stack) rather than breaking
            // the user's browser with 503 Service Unavailable / ERR_TUNNEL_CONNECTION_FAILED.
            let reason = !canForward() ? "VPN disconnected" : "domain paused"
            AppLogger.log("local proxy: direct bypass for \(target.host):\(target.port) (\(reason))")
        }

        let upstream = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: upstreamParams
        )
        var connectTimer: DispatchSourceTimer? = DispatchSource.makeTimerSource(queue: queue)
        connectTimer?.schedule(deadline: .now() + 12.0)
        connectTimer?.setEventHandler { [weak self, weak upstream, weak client] in
            guard let self, let upstream, let client else { return }
            AppLogger.log("local proxy: upstream \(target.host):\(target.port) connection timed out after 12s")
            upstream.cancel()
            self.sendProxyResponse(status: "504 Gateway Timeout", body: "SemiVPN: connection to \(target.host):\(target.port) timed out.\n", on: client)
        }
        connectTimer?.resume()

        let cancelTimer = {
            connectTimer?.cancel()
            connectTimer = nil
        }

        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                cancelTimer()
                upstream.stateUpdateHandler = nil
                let iface = upstream.currentPath?.availableInterfaces.first?.name ?? "unknown"
                AppLogger.log("local proxy: upstream \(target.host):\(target.port) ready on \(iface)")
                if request.method == "CONNECT" {
                    self.sendData(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), on: client) { error in
                        if let error {
                            AppLogger.log("local proxy: CONNECT response failed: \(error)")
                            upstream.cancel()
                            client.cancel()
                            return
                        }
                        if !request.trailing.isEmpty {
                            upstream.send(content: request.trailing, completion: .contentProcessed { sendError in
                                if let sendError {
                                    AppLogger.log("local proxy: CONNECT initial data failed: \(sendError)")
                                    upstream.cancel()
                                    client.cancel()
                                    return
                                }
                                ProxyRelay(client: client, upstream: upstream, queue: self.queue).start()
                            })
                        } else {
                            ProxyRelay(client: client, upstream: upstream, queue: self.queue).start()
                        }
                    }
                } else {
                    let outbound = self.rewrittenHTTPRequest(request, target: target)
                    upstream.send(content: outbound, completion: .contentProcessed { sendError in
                        if let sendError {
                            AppLogger.log("local proxy: HTTP request failed: \(sendError)")
                            upstream.cancel()
                            client.cancel()
                            return
                        }
                        ProxyRelay(client: client, upstream: upstream, queue: self.queue).start()
                    })
                }
            case .waiting(let error):
                AppLogger.log("local proxy: upstream \(target.host):\(target.port) waiting: \(error), path=\(String(describing: upstream.currentPath))")
                if case .posix(let code) = error, code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH {
                    cancelTimer()
                    upstream.cancel()
                    self.sendProxyResponse(status: "502 Bad Gateway", body: "SemiVPN: host unreachable (\(error)).\n", on: client)
                }
            case .preparing:
                AppLogger.log("local proxy: upstream \(target.host):\(target.port) preparing, path=\(String(describing: upstream.currentPath))")
            case .setup:
                AppLogger.log("local proxy: upstream \(target.host):\(target.port) setup")
            case .failed(let error):
                cancelTimer()
                AppLogger.log("local proxy: upstream \(target.host):\(target.port) failed: \(error), path=\(String(describing: upstream.currentPath))")
                self.sendProxyResponse(status: "502 Bad Gateway", body: "SemiVPN could not reach the target: \(error.localizedDescription)\n", on: client)
            case .cancelled:
                cancelTimer()
                AppLogger.log("local proxy: upstream \(target.host):\(target.port) cancelled")
                client.cancel()
            @unknown default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func parseAuthority(_ value: String, defaultPort: UInt16) -> ProxyTarget? {
        let pieces = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard let host = pieces.first, !host.isEmpty else { return nil }
        let port = pieces.count == 2 ? UInt16(pieces[1]) : defaultPort
        guard let port, port > 0 else { return nil }
        return ProxyTarget(host: host, port: port)
    }

    private func parseHTTPURL(_ value: String) -> ProxyTarget? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "http",
              let host = url.host, !host.isEmpty else { return nil }
        let portValue = url.port ?? 80
        guard portValue > 0, portValue <= Int(UInt16.max) else { return nil }
        let port = UInt16(portValue)
        return ProxyTarget(host: host, port: port)
    }

    private func rewrittenHTTPRequest(_ request: HTTPRequest, target: ProxyTarget) -> Data {
        guard let url = URL(string: request.target) else { return request.raw }
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?\(query)" }

        var lines = ["\(request.method) \(path) HTTP/\(request.httpVersion)"]
        for (name, value) in request.headers where name != "proxy-connection" {
            lines.append("\(name): \(value)")
        }
        if !request.headers.keys.contains("host") {
            lines.append("Host: \(target.host)")
        }
        lines.append("")
        lines.append("")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(request.body)
        data.append(request.trailing)
        return data
    }

    // MARK: - Local control API

    private func handleControlConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection) { [weak self] request in
            guard let self else {
                connection.cancel()
                return
            }
            self.handleControlRequest(request, connection: connection)
        }
    }

    private func handleControlRequest(_ request: HTTPRequest, connection: NWConnection) {
        let components = URLComponents(string: "http://localhost\(request.target)")
        let path = components?.path ?? request.target

        // A normal webpage must not be able to mutate the routing policy via
        // a browser CORS request. The unpacked Chrome extension has a
        // chrome-extension:// origin; native callers such as curl omit it.
        if let origin = request.headers["origin"], !origin.hasPrefix("chrome-extension://") {
            sendControlResponse(status: "403 Forbidden", body: Data("Only the SemiVPN Chrome extension may call this API.\n".utf8), on: connection)
            return
        }

        if request.method == "OPTIONS" {
            sendControlResponse(status: "204 No Content", body: Data(), on: connection)
            return
        }

        switch (request.method, path) {
        case ("GET", "/v1/status"):
            let domainConfiguration = SharedConfig.loadDomainConfiguration()
            let selection = SharedConfig.loadSelection()
            let status = LocalAPIStatus(
                proxyHost: "127.0.0.1",
                proxyPort: SharedConfig.localProxyPort,
                controlHost: "127.0.0.1",
                controlPort: SharedConfig.localControlPort,
                forwardingAllowed: canForward(),
                vpnStatus: currentVPNStatus(),
                routingMode: selection?.routingMode.rawValue ?? "not-configured",
                fullTunnel: selection?.fullTunnel ?? false,
                domainRouting: selection?.domainRouting ?? false,
                domains: domainConfiguration.domains,
                activeDomains: domainConfiguration.activeDomains,
                inactiveDomains: domainConfiguration.inactiveDomains,
                subdomainDomains: domainConfiguration.subdomainDomains,
                activeSubdomainDomains: domainConfiguration.activeSubdomainDomains,
                revision: domainConfiguration.revision,
                updatedAt: domainConfiguration.updatedAt
            )
            sendJSON(status, status: "200 OK", on: connection)
        case ("GET", "/v1/domains"):
            sendJSON(SharedConfig.loadDomainConfiguration(), status: "200 OK", on: connection)
        case ("POST", "/v1/domains"):
            guard let mutation = try? JSONDecoder().decode(DomainMutation.self, from: request.body) else {
                sendControlResponse(status: "400 Bad Request", body: Data("Expected JSON: {\"domain\":\"example.com\",\"includeSubdomains\":true}".utf8), on: connection)
                return
            }
            do {
                let configuration = try SharedConfig.addDomain(mutation.domain, includeSubdomains: mutation.includeSubdomains ?? true)
                notifyDomainConfigurationChanged()
                sendJSON(configuration, status: "200 OK", on: connection)
            } catch {
                sendControlResponse(status: "422 Unprocessable Entity", body: Data((error.localizedDescription + "\n").utf8), on: connection)
            }
        case ("PATCH", "/v1/domains"):
            guard let mutation = try? JSONDecoder().decode(DomainToggle.self, from: request.body) else {
                sendControlResponse(status: "400 Bad Request", body: Data("Expected JSON: {\"domain\":\"example.com\",\"enabled\":true}".utf8), on: connection)
                return
            }
            do {
                let configuration = try SharedConfig.setDomainEnabled(mutation.domain, enabled: mutation.enabled)
                notifyDomainConfigurationChanged()
                sendJSON(configuration, status: "200 OK", on: connection)
            } catch {
                sendControlResponse(status: "422 Unprocessable Entity", body: Data((error.localizedDescription + "\n").utf8), on: connection)
            }
        case ("DELETE", "/v1/domains"):
            guard let domain = components?.queryItems?.first(where: { $0.name == "domain" })?.value else {
                sendControlResponse(status: "400 Bad Request", body: Data("Missing domain query parameter.\n".utf8), on: connection)
                return
            }
            do {
                let configuration = try SharedConfig.removeDomain(domain)
                notifyDomainConfigurationChanged()
                sendJSON(configuration, status: "200 OK", on: connection)
            } catch {
                sendControlResponse(status: "422 Unprocessable Entity", body: Data((error.localizedDescription + "\n").utf8), on: connection)
            }
        default:
            sendControlResponse(status: "404 Not Found", body: Data("Not found.\n".utf8), on: connection)
        }
    }

    private func sendJSON<T: Encodable>(_ value: T, status: String, on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(value) else {
            sendControlResponse(status: "500 Internal Server Error", body: Data("Could not encode response.\n".utf8), on: connection)
            return
        }
        sendControlResponse(status: status, body: body, contentType: "application/json", on: connection)
    }

    // MARK: - HTTP framing

    private func receiveRequest(on connection: NWConnection, buffer: Data = Data(), completion: @escaping (HTTPRequest) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                AppLogger.log("local HTTP receive failed: \(error)")
                connection.cancel()
                return
            }

            var next = buffer
            if let data { next.append(data) }
            guard next.count <= 128 * 1024 else {
                connection.cancel()
                return
            }

            guard let separator = next.range(of: Self.headerSeparator) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection, buffer: next, completion: completion)
                }
                return
            }

            let headerData = next.subdata(in: next.startIndex..<separator.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8),
                  let request = HTTPRequest(header: header) else {
                connection.cancel()
                return
            }

            let afterHeaders = next.subdata(in: separator.upperBound..<next.endIndex)
            let bodyLength = request.contentLength
            if afterHeaders.count < bodyLength && !isComplete {
                self.receiveRequest(on: connection, buffer: next, completion: completion)
                return
            }
            guard afterHeaders.count >= bodyLength else {
                connection.cancel()
                return
            }
            var complete = request
            complete.body = Data(afterHeaders.prefix(bodyLength))
            complete.trailing = Data(afterHeaders.dropFirst(bodyLength))
            completion(complete)
        }
    }

    private func sendProxyResponse(status: String, body: String, on connection: NWConnection) {
        sendData(Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8), on: connection) { _ in
            connection.cancel()
        }
    }

    private func sendControlResponse(status: String, body: Data, contentType: String = "text/plain; charset=utf-8", on connection: NWConnection) {
        var response = Data("HTTP/1.1 \(status)\r\n".utf8)
        response.append(Data("Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8))
        response.append(body)
        sendData(response, on: connection) { _ in
            connection.cancel()
        }
    }

    private func sendData(_ data: Data, on connection: NWConnection, completion: @escaping (NWError?) -> Void) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    private static func listenerStateDescription(_ state: NWListener.State) -> String {
        switch state {
        case .setup: return "setup"
        case .waiting(let error): return "waiting (\(error))"
        case .ready: return "ready"
        case .failed(let error): return "failed (\(error))"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    private struct ProxyTarget {
        let host: String
        let port: UInt16
    }

    private struct DomainMutation: Decodable {
        let domain: String
        let includeSubdomains: Bool?
    }

    private struct DomainToggle: Decodable {
        let domain: String
        let enabled: Bool
    }

    private struct LocalAPIStatus: Encodable {
        let proxyHost: String
        let proxyPort: UInt16
        let controlHost: String
        let controlPort: UInt16
        let forwardingAllowed: Bool
        let vpnStatus: String
        let routingMode: String
        let fullTunnel: Bool
        let domainRouting: Bool
        let domains: [String]
        let activeDomains: [String]
        let inactiveDomains: [String]
        let subdomainDomains: [String]
        let activeSubdomainDomains: [String]
        let revision: Int
        let updatedAt: Date
    }

    private struct HTTPRequest {
        let method: String
        let target: String
        let httpVersion: String
        let headers: [String: String]
        let raw: Data
        var body = Data()
        var trailing = Data()

        var contentLength: Int {
            max(0, Int(headers["content-length"] ?? "0") ?? 0)
        }

        init?(header: String) {
            let lines = header.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            let version = parts[2].hasPrefix("HTTP/") ? String(parts[2].dropFirst(5)) : "1.1"
            var parsedHeaders: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { parsedHeaders[name] = value }
            }
            method = parts[0].uppercased()
            target = parts[1]
            httpVersion = version
            headers = parsedHeaders
            raw = Data(header.utf8)
        }
    }

    private final class ProxyRelay {
        let client: NWConnection
        let upstream: NWConnection
        let queue: DispatchQueue

        init(client: NWConnection, upstream: NWConnection, queue: DispatchQueue) {
            self.client = client
            self.upstream = upstream
            self.queue = queue
        }

        func start() {
            pipe(from: client, to: upstream)
            pipe(from: upstream, to: client)
        }

        private func pipe(from source: NWConnection, to destination: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                if let data, !data.isEmpty {
                    destination.send(content: data, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            source.cancel()
                            destination.cancel()
                        } else {
                            self.pipe(from: source, to: destination)
                        }
                    })
                } else if isComplete || error != nil {
                    source.cancel()
                    destination.cancel()
                } else {
                    self.pipe(from: source, to: destination)
                }
            }
        }
    }
}
