import Foundation
import NetworkExtension
import Darwin

/// Splices a proxied TCP flow through a raw socket.
///
/// The socket is bound to the interface the provider chose: the tunnel's
/// utun for selected apps, the physical interface (`IP_BOUND_IF`) for
/// everything else. Binding is mandatory in per-app mode — the tunnel
/// installs no default route, so an unbound socket would leak around the
/// tunnel on the physical interface.
final class FlowProxy {
    private static let queue = DispatchQueue(label: "com.semivpn.flows", qos: .userInitiated)

    static func splice(_ flow: NEAppProxyTCPFlow,
                       bindInterface: String?,
                       log: @escaping (String) -> Void) {
        guard let remote = flow.remoteEndpoint as? NWHostEndpoint else {
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return
        }

        queue.async {
            let proxy = FlowProxyInstance(
                flow: flow,
                host: remote.hostname,
                port: remote.port,
                bindInterface: bindInterface,
                log: log
            )
            proxy.start()
        }
    }
}

private final class FlowProxyInstance {
    private let flow: NEAppProxyTCPFlow
    private let host: String
    private let port: String
    private let bindInterface: String?
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "com.semivpn.flow", qos: .userInitiated)

    private var socketFD: Int32 = -1
    private var writeSource: DispatchSourceWrite?
    private var readSource: DispatchSourceRead?
    private var connected = false
    private var pendingWrites = Data()
    private var closed = false
    // The provider creates this relay from an asynchronous closure. Keep the
    // relay alive until the flow is closed; otherwise the local variable in
    // FlowProxy.splice goes out of scope immediately after start().
    private var keepAlive: FlowProxyInstance?

    init(flow: NEAppProxyTCPFlow, host: String, port: String, bindInterface: String?, log: @escaping (String) -> Void) {
        self.flow = flow
        self.host = host
        self.port = port
        self.bindInterface = bindInterface
        self.log = log
    }

    func start() {
        keepAlive = self
        socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { failAndClose(); return }
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        if let iface = bindInterface {
            let ifindex = if_nametoindex(iface)
            guard ifindex != 0 else {
                log("tcp: bind interface \(iface) not found")
                failAndClose()
                return
            }
            var index = ifindex
            setsockopt(socketFD, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }

        guard let portNumber = UInt16(port),
              let addr = resolve(host, port: portNumber) else {
            failAndClose()
            return
        }

        let rc = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(addr.ss_len))
            }
        }
        if rc != 0 {
            let err = errno
            guard err == EINPROGRESS else {
                log("connect failed for \(host):\(port) errno=\(err)")
                failAndClose()
                return
            }
        }

        // One writability source drives connect completion, then drains
        // any pending writes for the life of the connection.
        let write = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: queue)
        write.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.connected {
                var error: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(self.socketFD, SOL_SOCKET, SO_ERROR, &error, &len)
                guard error == 0 else {
                    self.log("socket connect error: \(error)")
                    self.failAndClose()
                    return
                }
                self.connected = true
                self.didConnect()
            }
            self.drainWrites()
        }
        write.resume()
        writeSource = write
    }

    private func didConnect() {
        log("socket connected to \(host):\(port)")
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            // NE calls flow completions on its own queue; all state lives
            // on the proxy's serial queue.
            guard let self else { return }
            self.queue.async { self.didOpen(error: error) }
        }
    }

    private func didOpen(error: Error?) {
        if let error {
            log("flow open error: \(error)")
            closeAll()
            return
        }

        let read = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        read.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        read.resume()
        readSource = read

        nextFlowRead()
    }

    private func nextFlowRead() {
        flow.readData(completionHandler: { [weak self] data, error in
            guard let self else { return }
            self.queue.async { self.handleFlowRead(data: data, error: error) }
        })
    }

    private func handleFlowRead(data: Data?, error: Error?) {
        if let error {
            log("flow read error: \(error)")
            closeAll()
            return
        }
        guard let data, !data.isEmpty else {
            log("flow EOF")
            closeAll()
            return
        }
        writeToSocket(data)
        nextFlowRead()
    }

    /// Appends to the pending buffer and attempts to flush it; what cannot
    /// be sent now is drained by the writability source.
    private func writeToSocket(_ data: Data) {
        guard socketFD >= 0 else { return }
        if pendingWrites.isEmpty {
            pendingWrites.append(data)
            drainWrites()
        } else {
            pendingWrites.append(data)
        }
    }

    private func drainWrites() {
        guard socketFD >= 0, connected else { return }
        while !pendingWrites.isEmpty {
            let result = pendingWrites.withUnsafeBytes { ptr in
                Darwin.send(socketFD, ptr.baseAddress, pendingWrites.count, 0)
            }
            if result > 0 {
                pendingWrites.removeFirst(result)
            } else if result < 0 {
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    log("socket send error: \(err)")
                    closeAll()
                }
                return
            }
        }
    }

    private func drainSocket() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while socketFD >= 0 {
            let n = Darwin.recv(socketFD, &buffer, buffer.count, 0)
            if n > 0 {
                flow.write(Data(buffer.prefix(n)), withCompletionHandler: { [weak self] error in
                    guard let error else { return }
                    self?.queue.async {
                        self?.log("flow write error: \(error)")
                        self?.closeAll()
                    }
                })
            } else if n == 0 {
                log("socket EOF")
                closeAll()
                return
            } else {
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    log("socket read error: \(err)")
                    closeAll()
                }
                return
            }
        }
    }

    private func closeAll() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        keepAlive = nil
    }

    private func failAndClose() {
        closeAll()
    }

    private func resolve(_ host: String, port: UInt16) -> sockaddr_storage? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }
        return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_storage.self, capacity: 1) { $0.pointee }
    }
}
