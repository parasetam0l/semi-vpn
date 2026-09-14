import Foundation
import NetworkExtension
import Darwin

/// Relays a proxied UDP flow through a raw UDP socket: the message-based
/// counterpart of FlowProxy's TCP splice.
///
/// - The socket is bound to the interface the provider chose (the tunnel's
///   utun for selected apps, the physical interface otherwise).
/// - Each datagram read from the flow is sent to the endpoint the app
///   addressed it to; replies are written back with their source endpoint.
/// - Flows idle for two minutes are closed (UDP has no EOF).
final class UDPFlowProxy {
    private static let queue = DispatchQueue(label: "com.semivpn.udprelays", qos: .userInitiated)
    private static let idleTimeout: TimeInterval = 120

    static func splice(_ flow: NEAppProxyUDPFlow,
                       bindInterface: String?,
                       log: @escaping (String) -> Void) {
        queue.async {
            let relay = UDPFlowProxy(flow: flow, bindInterface: bindInterface, log: log)
            relay.start()
        }
    }

    private let flow: NEAppProxyUDPFlow
    private let bindInterface: String?
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "com.semivpn.udprelay", qos: .userInitiated)

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var idleTimer: DispatchSourceTimer?
    private var closed = false
    private var lastActivity = Date()
    // Keep the relay alive after splice()'s asynchronous setup closure exits.
    private var keepAlive: UDPFlowProxy?

    private init(flow: NEAppProxyUDPFlow, bindInterface: String?, log: @escaping (String) -> Void) {
        self.flow = flow
        self.bindInterface = bindInterface
        self.log = log
    }

    private func start() {
        keepAlive = self
        socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            log("udp socket creation failed: \(errno)")
            closeAll()
            return
        }
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        if let iface = bindInterface {
            let ifindex = if_nametoindex(iface)
            guard ifindex != 0 else {
                log("udp: bind interface \(iface) not found")
                closeAll()
                return
            }
            var index = ifindex
            setsockopt(socketFD, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }

        flow.open(withLocalEndpoint: nil) { [weak self] error in
            // NE calls flow completions on its own queue; all state lives
            // on the relay's serial queue.
            guard let self else { return }
            self.queue.async { self.didOpen(error: error) }
        }
    }

    private func didOpen(error: Error?) {
        if let error {
            log("udp flow open error: \(error)")
            closeAll()
            return
        }
        let read = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        read.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        read.resume()
        readSource = read
        scheduleIdleCheck()
        nextFlowRead()
        log("udp flow relay up (bind: \(bindInterface ?? "default"))")
    }

    // MARK: - Flow side

    private func nextFlowRead() {
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self else { return }
            self.queue.async {
                self.handleFlowRead(datagrams: datagrams, endpoints: endpoints, error: error)
            }
        }
    }

    private func handleFlowRead(datagrams: [Data]?, endpoints: [NWEndpoint]?, error: Error?) {
        guard !closed else { return }
        if let error {
            log("udp flow read error: \(error)")
            closeAll()
            return
        }
        guard let datagrams, !datagrams.isEmpty else {
            log("udp flow closed by app")
            closeAll()
            return
        }
        touch()
        for (index, datagram) in datagrams.enumerated() {
            // readDatagrams pairs each datagram with its destination
            // endpoint (UDP flows carry no single remote endpoint).
            guard let destinations = endpoints, destinations.count == datagrams.count else {
                log("udp: datagram without destination endpoint, dropped \(datagram.count)B")
                continue
            }
            sendDatagram(datagram, to: destinations[index])
        }
        nextFlowRead()
    }

    private func sendDatagram(_ datagram: Data, to endpoint: NWEndpoint) {
        guard socketFD >= 0, let sin = sockaddrFor(endpoint) else {
            log("udp: unusable destination endpoint, dropped \(datagram.count)B")
            return
        }
        let sent = datagram.withUnsafeBytes { ptr -> Int in
            withUnsafePointer(to: sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, ptr.baseAddress, datagram.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            log("udp sendto error: \(errno)")
        }
    }

    // MARK: - Socket side

    private func drainSocket() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while socketFD >= 0 {
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &source) { srcPtr in
                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { srcSock in
                    recvfrom(socketFD, &buffer, buffer.count, 0, srcSock, &length)
                }
            }
            if n > 0 {
                touch()
                guard let origin = endpointFrom(source) else {
                    log("udp: reply from non-IPv4 source, dropped \(n)B")
                    continue
                }
                let datagram = Data(buffer.prefix(n))
                flow.writeDatagrams([datagram], sentBy: [origin]) { [weak self] error in
                    guard let error else { return }
                    self?.queue.async {
                        self?.log("udp flow write error: \(error)")
                        self?.closeAll()
                    }
                }
                continue
            }
            if n < 0 {
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    log("udp recvfrom error: \(err)")
                    closeAll()
                }
            }
            return
        }
    }

    // MARK: - Idle handling

    private func scheduleIdleCheck() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleTimeout / 2, repeating: Self.idleTimeout / 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            if Date().timeIntervalSince(self.lastActivity) > Self.idleTimeout {
                self.log("udp flow idle, closing")
                self.closeAll()
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func touch() {
        lastActivity = Date()
    }

    // MARK: - Teardown

    private func closeAll() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        idleTimer?.cancel()
        idleTimer = nil
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        keepAlive = nil
    }

    // MARK: - Endpoint conversion

    /// Flow endpoint → AF_INET sockaddr (nil for IPv6 or non-host
    /// endpoints, which the current AF_INET transport cannot carry).
    private func sockaddrFor(_ endpoint: NWEndpoint?) -> sockaddr_in? {
        guard let hostEndpoint = endpoint as? NWHostEndpoint,
              let sin = Self.resolve(host: hostEndpoint.hostname, port: hostEndpoint.port) else {
            return nil
        }
        return sin
    }

    /// sockaddr_in → NWHostEndpoint (nil for non-IPv4 sources).
    private func endpointFrom(_ sin: sockaddr_in) -> NWHostEndpoint? {
        guard sin.sin_family == sa_family_t(AF_INET) else { return nil }
        var addr = sin.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: buffer)
        let port = UInt16(bigEndian: sin.sin_port)
        return NWHostEndpoint(hostname: host, port: String(port))
    }

    private static func resolve(host: String, port: String) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }
        guard first.pointee.ai_family == AF_INET, let addr = first.pointee.ai_addr else {
            return nil
        }
        return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }
}
