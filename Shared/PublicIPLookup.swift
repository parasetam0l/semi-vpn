import Foundation
import Network

/// Looks up the public IP addresses the internet sees for this process,
/// with icanhazip.com: ipv4.icanhazip.com has only an IPv4 address and
/// ipv6.icanhazip.com only an IPv6 one, so each answers in its own family.
///
/// The app looks up the addresses without the VPN; SemiProxy, which macOS
/// routes through the VPN, looks them up with it (`SemiProxy --public-ip`).
public enum PublicIPLookup {
    public enum Family: Sendable {
        case v4, v6
    }

    public enum Outcome: Codable, Equatable, Sendable {
        case address(String)
        /// No answer in this family, e.g. the network has no IPv6.
        case unavailable(String)
    }

    public struct Result: Codable, Equatable, Sendable {
        public var v4: Outcome
        public var v6: Outcome

        public init(v4: Outcome, v6: Outcome) {
            self.v4 = v4
            self.v6 = v6
        }
    }

    /// Both families at once. `avoidingTunnels` keeps the lookups off VPN
    /// interfaces (utun), which a full-tunnel VPN would otherwise use.
    public static func lookUp(avoidingTunnels: Bool, timeout: TimeInterval = 8) async -> Result {
        async let v4 = lookUp(.v4, avoidingTunnels: avoidingTunnels, timeout: timeout)
        async let v6 = lookUp(.v6, avoidingTunnels: avoidingTunnels, timeout: timeout)
        return await Result(v4: v4, v6: v6)
    }

    public static func lookUp(_ family: Family, avoidingTunnels: Bool, timeout: TimeInterval) async -> Outcome {
        let host = family == .v4 ? "ipv4.icanhazip.com" : "ipv6.icanhazip.com"
        let parameters = NWParameters.tls
        if avoidingTunnels {
            parameters.prohibitedInterfaceTypes = [.other]
        }
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = family == .v4 ? .v4 : .v6
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: parameters)
        let queue = DispatchQueue(label: "com.semivpn.public-ip")
        let request = Request(connection: connection, family: family)

        return await withCheckedContinuation { continuation in
            request.onFinish = { continuation.resume(returning: $0) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // HTTP/1.0: the answer is never chunked and ends with
                    // the connection.
                    let text = "GET / HTTP/1.0\r\nHost: \(host)\r\nUser-Agent: SemiVPN\r\n\r\n"
                    connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                        if let error {
                            request.finish(.unavailable(error.localizedDescription))
                        } else {
                            request.receive()
                        }
                    })
                case .waiting(let error), .failed(let error):
                    // Waiting means no route in this family now: don't wait.
                    request.finish(.unavailable(error.localizedDescription))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                request.finish(.unavailable("No answer from \(host)."))
            }
        }
    }

    /// One lookup's state; used on its connection's queue only.
    private final class Request: @unchecked Sendable {
        let connection: NWConnection
        let family: Family
        var onFinish: ((Outcome) -> Void)?
        private var received = Data()
        private var finished = false

        init(connection: NWConnection, family: Family) {
            self.connection = connection
            self.family = family
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, isComplete, error in
                if let data { received.append(data) }
                if isComplete || received.count > 16_384 {
                    finish(PublicIPLookup.parse(received, family: family))
                } else if let error {
                    finish(.unavailable(error.localizedDescription))
                } else {
                    receive()
                }
            }
        }

        func finish(_ outcome: Outcome) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            onFinish?(outcome)
            onFinish = nil
        }
    }

    /// The address in an HTTP answer whose body is just that address.
    static func parse(_ response: Data, family: Family) -> Outcome {
        let text = String(decoding: response, as: UTF8.self)
        guard let separator = text.range(of: "\r\n\r\n") else {
            return .unavailable("Unexpected answer.")
        }
        let statusLine = text[..<separator.lowerBound].prefix { $0 != "\r" }
        guard statusLine.split(separator: " ").dropFirst().first == "200" else {
            return .unavailable("Unexpected answer: \(statusLine)")
        }
        let body = text[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        switch family {
        case .v4 where IPv4Address(body) != nil, .v6 where IPv6Address(body) != nil:
            return .address(body)
        default:
            return .unavailable("Unexpected answer.")
        }
    }
}
