import Foundation
import Darwin

public enum PushParseError: Error, Sendable, Equatable {
    case malformedMessage
}

/// An IPv4 route pushed by the server (`route network [netmask] [gateway] [metric]`).
public struct PushedRoute: Sendable, Equatable {
    public var network: String
    public var netmask: String
    /// An explicit gateway address; nil for the VPN gateway (`vpn_gateway`
    /// or no gateway given).
    public var gateway: String?
    public var metric: Int?
    /// `net_gateway`: the destination must bypass the tunnel.
    public var excluded: Bool

    public init(network: String, netmask: String = "255.255.255.255", gateway: String? = nil,
                metric: Int? = nil, excluded: Bool = false) {
        self.network = network
        self.netmask = netmask
        self.gateway = gateway
        self.metric = metric
        self.excluded = excluded
    }
}

/// The options a server pushes in its `PUSH_REPLY` message(s).
public struct PushedOptions: Sendable, Equatable {
    public var peerID: UInt32?
    public var cipher: OVPNProfile.Cipher?
    /// A pushed data cipher this client does not implement. The connection
    /// must fail instead of silently keeping its own cipher.
    public var unsupportedCipher: String?
    public var digest: OVPNProfile.Digest?
    public var useTLSKeyExport: Bool
    public var pingSeconds: Int?
    public var pingRestartSeconds: Int?
    public var renegSeconds: Int?
    public var ifconfigLocal: String?
    /// The second `ifconfig` argument: the netmask with `topology subnet`,
    /// the point-to-point peer address with net30/p2p.
    public var ifconfigRemote: String?
    public var routeGateway: String?
    public var topology: String?
    /// IPv4 DNS servers: `dns server N address` entries (ordered by
    /// priority) when present, otherwise `dhcp-option DNS`.
    public var dnsServers: [String]
    public var aeadEpoch: Bool
    public var ifconfigIPv6Local: String?
    public var ifconfigIPv6Netbits: Int?
    public var ifconfigIPv6Remote: String?
    public var routeIPv6Gateway: String?
    public var routesIPv6: [OVPNProfile.RouteIPv6]
    public var redirectGatewayIPv6: Bool
    public var dnsIPv6Servers: [String]
    /// IPv4 routes (`route`).
    public var routes: [PushedRoute]
    /// `redirect-gateway` without `!ipv4`: the tunnel becomes the IPv4
    /// default route.
    public var redirectGateway: Bool
    /// DNS search domains (`dhcp-option DOMAIN`/`DOMAIN-SEARCH`,
    /// `dns search-domains`).
    public var searchDomains: [String]
    /// Split-DNS domains resolved by the pushed servers
    /// (`dns server N resolve-domains`).
    public var dnsResolveDomains: [String]
    public var tunMTU: Int?
    /// `protocol-flags` keywords (cc-exit, tls-ekm, aead-epoch, ...).
    public var protocolFlags: Set<String>
    /// `push-continuation 2`: more PUSH_REPLY messages follow.
    public var continuation: Int?
    /// `auth-token`: used instead of the password on later reconnects.
    public var authToken: String?
    /// `auth-token-user` (base64): the username to send with the token.
    public var authTokenUser: String?
    /// `block-ipv6`: IPv6 must not leak outside the tunnel.
    public var blockIPv6: Bool
    /// Raw options, in the order they were received.
    public var raw: [String]

    public init(
        peerID: UInt32? = nil,
        cipher: OVPNProfile.Cipher? = nil,
        digest: OVPNProfile.Digest? = nil,
        useTLSKeyExport: Bool = false,
        pingSeconds: Int? = nil,
        pingRestartSeconds: Int? = nil,
        renegSeconds: Int? = nil,
        ifconfigLocal: String? = nil,
        ifconfigRemote: String? = nil,
        routeGateway: String? = nil,
        topology: String? = nil,
        dnsServers: [String] = [],
        aeadEpoch: Bool = false,
        ifconfigIPv6Local: String? = nil,
        ifconfigIPv6Netbits: Int? = nil,
        ifconfigIPv6Remote: String? = nil,
        routeIPv6Gateway: String? = nil,
        routesIPv6: [OVPNProfile.RouteIPv6] = [],
        redirectGatewayIPv6: Bool = false,
        dnsIPv6Servers: [String] = [],
        routes: [PushedRoute] = [],
        redirectGateway: Bool = false,
        searchDomains: [String] = [],
        dnsResolveDomains: [String] = [],
        tunMTU: Int? = nil,
        protocolFlags: Set<String> = [],
        continuation: Int? = nil,
        authToken: String? = nil,
        authTokenUser: String? = nil,
        blockIPv6: Bool = false,
        unsupportedCipher: String? = nil,
        raw: [String] = []
    ) {
        self.peerID = peerID
        self.cipher = cipher
        self.digest = digest
        self.useTLSKeyExport = useTLSKeyExport
        self.pingSeconds = pingSeconds
        self.pingRestartSeconds = pingRestartSeconds
        self.renegSeconds = renegSeconds
        self.ifconfigLocal = ifconfigLocal
        self.ifconfigRemote = ifconfigRemote
        self.routeGateway = routeGateway
        self.topology = topology
        self.dnsServers = dnsServers
        self.aeadEpoch = aeadEpoch
        self.ifconfigIPv6Local = ifconfigIPv6Local
        self.ifconfigIPv6Netbits = ifconfigIPv6Netbits
        self.ifconfigIPv6Remote = ifconfigIPv6Remote
        self.routeIPv6Gateway = routeIPv6Gateway
        self.routesIPv6 = routesIPv6
        self.redirectGatewayIPv6 = redirectGatewayIPv6
        self.dnsIPv6Servers = dnsIPv6Servers
        self.routes = routes
        self.redirectGateway = redirectGateway
        self.searchDomains = searchDomains
        self.dnsResolveDomains = dnsResolveDomains
        self.tunMTU = tunMTU
        self.protocolFlags = protocolFlags
        self.continuation = continuation
        self.authToken = authToken
        self.authTokenUser = authTokenUser
        self.blockIPv6 = blockIPv6
        self.unsupportedCipher = unsupportedCipher
        self.raw = raw
    }

    /// True when the server announced control-channel exit notification.
    public var supportsControlChannelExit: Bool { protocolFlags.contains("cc-exit") }

    /// Whether the second `ifconfig` argument is a netmask. With
    /// `topology subnet` it always is; without a pushed topology a value
    /// that is a valid contiguous netmask is treated as one (OpenVPN 2.7
    /// servers default to subnet).
    public var ifconfigUsesSubnet: Bool {
        if let topology { return topology == "subnet" }
        guard let remote = ifconfigRemote else { return false }
        return IPv4.isNetmask(remote)
    }

    /// The IPv4 netmask for the tunnel interface.
    public var ipv4SubnetMask: String {
        ifconfigUsesSubnet ? (ifconfigRemote ?? "255.255.255.0") : "255.255.255.255"
    }

    /// The tunnel's IPv4 next hop: the pushed `route-gateway`, or the
    /// point-to-point peer with net30/p2p.
    public var ipv4Gateway: String? {
        routeGateway ?? (ifconfigUsesSubnet ? nil : ifconfigRemote)
    }
}

/// A non-PUSH_REPLY control-channel message from the server.
public enum ServerControlMessage: Sendable, Equatable {
    /// `AUTH_FAILED[,reason]`. `TEMP[flags]:` marks a temporary rejection
    /// that may be retried after `backoff` seconds.
    case authFailed(reason: String, temporary: Bool, backoffSeconds: Int?)
    /// `AUTH_PENDING[,timeout N,...]`: authentication continues out of band
    /// (2FA, web login); keep waiting up to the timeout.
    case authPending(timeoutSeconds: Int?, keywords: [String])
    /// `RESTART[,[flags]reason]`: reconnect; `[N]` asks for the next remote.
    case restart(reason: String, advanceRemote: Bool)
    /// `HALT[,reason]`: disconnect and do not reconnect.
    case halt(reason: String)
    /// `EXIT`: the server is shutting down (control-channel exit notify).
    case exit
    /// `INFO,...` / `INFO_PRE,...`.
    case info(String)
    case other(String)

    public static func parse(_ text: String) -> ServerControlMessage {
        func detail(after keyword: String) -> String {
            var rest = text.dropFirst(keyword.count)
            if rest.first == "," { rest = rest.dropFirst() }
            return String(rest)
        }
        if text.hasPrefix("AUTH_FAILED") {
            let reason = detail(after: "AUTH_FAILED")
            guard reason.hasPrefix("TEMP") else {
                return .authFailed(reason: reason, temporary: false, backoffSeconds: nil)
            }
            // TEMP[backoff 30,advance no]:message
            var flags = ""
            var message = String(reason.dropFirst("TEMP".count))
            if message.hasPrefix("["), let close = message.firstIndex(of: "]") {
                flags = String(message[message.index(after: message.startIndex)..<close])
                message = String(message[message.index(after: close)...])
            }
            if message.hasPrefix(":") { message.removeFirst() }
            let backoff = flags.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("backoff ") }
                .flatMap { Int($0.dropFirst("backoff ".count)) }
            return .authFailed(reason: message.trimmingCharacters(in: .whitespaces), temporary: true, backoffSeconds: backoff)
        }
        if text.hasPrefix("AUTH_PENDING") {
            let keywords = detail(after: "AUTH_PENDING").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            let timeout = keywords.first { $0.hasPrefix("timeout ") }
                .flatMap { Int($0.dropFirst("timeout ".count)) }
            return .authPending(timeoutSeconds: timeout, keywords: keywords)
        }
        if text.hasPrefix("RESTART") {
            var reason = detail(after: "RESTART")
            var advance = false
            if reason.hasPrefix("["), let close = reason.firstIndex(of: "]") {
                advance = reason[reason.startIndex..<close].contains("N")
                reason = String(reason[reason.index(after: close)...])
            }
            return .restart(reason: reason, advanceRemote: advance)
        }
        if text.hasPrefix("HALT") {
            return .halt(reason: detail(after: "HALT"))
        }
        if text == "EXIT" || text.hasPrefix("EXIT,") {
            return .exit
        }
        if text.hasPrefix("INFO") {
            return .info(text)
        }
        return .other(text)
    }
}

public enum PushMessage {
    case reply(PushedOptions)
    case authFailed(String)
    case restart(String)
    case halt
    case info(String)
    case other(String)
}

/// Parses control-channel payloads from the server.
public enum PushParser {
    /// Strips the control-channel string's trailing NUL(s).
    public static func text(of payload: Data) -> String {
        String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }

    /// `PUSH_REPLY,opt1,opt2,...`, or one of the other server messages.
    public static func parseReply(_ payload: Data) throws -> PushMessage {
        // Control-channel string messages carry a trailing NUL; it corrupts
        // the LAST option's value (e.g. a trailing "cipher AES-256-GCM").
        let text = text(of: payload)
        guard text.hasPrefix("PUSH_REPLY,") || text == "PUSH_REPLY" else {
            switch ServerControlMessage.parse(text) {
            case .authFailed(let reason, let temporary, _):
                return .authFailed(temporary ? "TEMP: " + reason : reason)
            case .restart(let reason, _):
                return .restart(reason)
            case .halt:
                return .halt
            case .info(let info):
                return .info(info)
            case .authPending, .exit, .other:
                return .other(text)
            }
        }
        return .reply(parse(options: splitOptions(text)))
    }

    /// Splits a PUSH_REPLY into its options.
    public static func splitOptions(_ text: String) -> [String] {
        let body = text.hasPrefix("PUSH_REPLY,") ? String(text.dropFirst("PUSH_REPLY,".count)) : ""
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        var options: [String] = []
        var index = 0
        while index < parts.count {
            let trimmed = String(parts[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            if trimmed.isEmpty { continue }
            if trimmed == "base64" {
                // The encoded payload follows as the next comma-separated part.
                guard index < parts.count else { break }
                let encoded = String(parts[index]).trimmingCharacters(in: .whitespaces)
                index += 1
                if let decoded = Data(base64Encoded: encoded),
                   let decodedText = String(data: decoded, encoding: .utf8) {
                    options.append(decodedText)
                }
            } else {
                options.append(trimmed)
            }
        }
        return options
    }

    /// Interprets pushed options. Continuation messages are merged by
    /// parsing the concatenated option lists.
    public static func parse(options: [String]) -> PushedOptions {
        var pushed = PushedOptions(raw: options)
        var dhcpDNS4: [String] = []
        var dhcpDNS6: [String] = []
        var dnsOptionServers: [(priority: Int, order: Int, address: String)] = []

        for option in options {
            let tokens = option.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let name = tokens.first else { continue }
            let args = Array(tokens.dropFirst())
            let value = args.joined(separator: " ")

            switch name {
            case "peer-id":
                pushed.peerID = UInt32(value).flatMap { $0 <= 0xFF_FFFF ? $0 : nil }
            case "cipher":
                if let cipher = OVPNProfile.Cipher(rawValue: value.uppercased()) {
                    pushed.cipher = cipher
                    pushed.unsupportedCipher = nil
                } else if !value.isEmpty {
                    pushed.unsupportedCipher = value
                }
            case "auth":
                pushed.digest = OVPNProfile.Digest(rawValue: value.uppercased())
            case "key-derivation":
                pushed.useTLSKeyExport = (value == "tls-ekm")
            case "protocol-flags":
                pushed.protocolFlags.formUnion(args)
                if args.contains("tls-ekm") { pushed.useTLSKeyExport = true }
                if args.contains("aead-epoch") { pushed.aeadEpoch = true }
            case "ping":
                pushed.pingSeconds = Int(value)
            case "ping-restart":
                pushed.pingRestartSeconds = Int(value)
            case "reneg-sec":
                pushed.renegSeconds = args.first.flatMap(Int.init)
            case "ifconfig":
                if args.count >= 2, IPv4.isAddress(args[0]) {
                    pushed.ifconfigLocal = args[0]
                    pushed.ifconfigRemote = args[1]
                }
            case "ifconfig-ipv6":
                if let first = args.first {
                    let (address, netbits) = splitPrefix(first)
                    pushed.ifconfigIPv6Local = address
                    pushed.ifconfigIPv6Netbits = netbits ?? 64
                }
                if args.count >= 2 {
                    pushed.ifconfigIPv6Remote = args[1]
                }
            case "route":
                if let route = parseRoute(args) {
                    pushed.routes.append(route)
                }
            case "route-ipv6":
                if let first = args.first {
                    let (prefix, netbits) = splitPrefix(first)
                    guard IPv6.isAddress(prefix) else { continue }
                    let gateway = args.count >= 2 ? args[1] : nil
                    pushed.routesIPv6.append(OVPNProfile.RouteIPv6(
                        prefix: prefix,
                        netbits: netbits ?? 128,
                        gateway: gateway == "vpn_gateway" ? nil : gateway,
                        metric: args.count >= 3 ? Int(args[2]) : nil
                    ))
                }
            case "route-ipv6-gateway":
                pushed.routeIPv6Gateway = args.first
            case "redirect-gateway":
                let flags = Set(args.map { $0.lowercased() })
                if !flags.contains("!ipv4") {
                    pushed.redirectGateway = true
                }
                if flags.contains("ipv6") {
                    pushed.redirectGatewayIPv6 = true
                }
            case "route-gateway":
                if let gateway = args.first, gateway != "dhcp" {
                    pushed.routeGateway = gateway
                }
            case "topology":
                pushed.topology = args.first
            case "tun-mtu":
                pushed.tunMTU = args.first.flatMap(Int.init)
            case "push-continuation":
                pushed.continuation = args.first.flatMap(Int.init)
            case "auth-token":
                pushed.authToken = args.first
            case "auth-token-user":
                pushed.authTokenUser = args.first
                    .flatMap { Data(base64Encoded: $0) }
                    .flatMap { String(data: $0, encoding: .utf8) }
            case "block-ipv6":
                pushed.blockIPv6 = true
            case "dns":
                parseDNSOption(args, into: &pushed, servers: &dnsOptionServers)
            case "dhcp-option":
                guard args.count >= 2 else { continue }
                let kind = args[0].uppercased()
                let argument = args[1]
                switch kind {
                case "DNS6":
                    dhcpDNS6.append(argument)
                case "DNS":
                    if argument.contains(":") {
                        dhcpDNS6.append(argument)
                    } else {
                        dhcpDNS4.append(argument)
                    }
                case "DOMAIN", "DOMAIN-SEARCH", "ADAPTER_DOMAIN_SUFFIX":
                    if !pushed.searchDomains.contains(argument) {
                        pushed.searchDomains.append(argument)
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        // `--dns server` options take precedence over `dhcp-option DNS`.
        if dnsOptionServers.isEmpty {
            pushed.dnsServers = dhcpDNS4
            pushed.dnsIPv6Servers = dhcpDNS6
        } else {
            let ordered = dnsOptionServers.sorted { ($0.priority, $0.order) < ($1.priority, $1.order) }
            pushed.dnsServers = ordered.map(\.address).filter { !$0.contains(":") }
            pushed.dnsIPv6Servers = ordered.map(\.address).filter { $0.contains(":") }
        }
        return pushed
    }

    /// `dns server N address A [B ...]`, `dns server N resolve-domains D...`,
    /// `dns search-domains D...` (OpenVPN 2.6+). Addresses may carry a port
    /// (`1.2.3.4:53`, `[::1]:53`), which macOS DNS settings cannot express;
    /// only the address is kept.
    private static func parseDNSOption(
        _ args: [String],
        into pushed: inout PushedOptions,
        servers: inout [(priority: Int, order: Int, address: String)]
    ) {
        guard let kind = args.first else { return }
        switch kind {
        case "search-domains":
            for domain in args.dropFirst() where !pushed.searchDomains.contains(domain) {
                pushed.searchDomains.append(domain)
            }
        case "server":
            guard args.count >= 4, let priority = Int(args[1]) else { return }
            switch args[2] {
            case "address":
                for raw in args.dropFirst(3) {
                    if let address = dnsAddress(raw) {
                        servers.append((priority, servers.count, address))
                    }
                }
            case "resolve-domains":
                for domain in args.dropFirst(3) where !pushed.dnsResolveDomains.contains(domain) {
                    pushed.dnsResolveDomains.append(domain)
                }
            default:
                break   // dnssec, transport, sni: not applicable to NEDNSSettings
            }
        default:
            // Non-standard `dns 1.1.1.1 8.8.8.8` form used by some servers.
            for raw in args {
                if let address = dnsAddress(raw) {
                    servers.append((0, servers.count, address))
                }
            }
        }
    }

    static func dnsAddress(_ raw: String) -> String? {
        if IPv4.isAddress(raw) || IPv6.isAddress(raw) { return raw }
        // [v6]:port
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            let address = String(raw[raw.index(after: raw.startIndex)..<close])
            return IPv6.isAddress(address) ? address : nil
        }
        // v4:port
        let parts = raw.split(separator: ":")
        if parts.count == 2, IPv4.isAddress(String(parts[0])) {
            return String(parts[0])
        }
        return nil
    }

    private static func parseRoute(_ args: [String]) -> PushedRoute? {
        guard let network = args.first, IPv4.isAddress(network) else { return nil }
        let netmask = args.count >= 2 && args[1] != "default" ? args[1] : "255.255.255.255"
        guard IPv4.isNetmask(netmask) else { return nil }
        var gateway: String?
        var excluded = false
        if args.count >= 3 {
            switch args[2] {
            case "net_gateway": excluded = true
            case "vpn_gateway", "default", "remote_host": gateway = nil
            default: gateway = IPv4.isAddress(args[2]) ? args[2] : nil
            }
        }
        let metric = args.count >= 4 ? Int(args[3]) : nil
        return PushedRoute(network: network, netmask: netmask, gateway: gateway, metric: metric, excluded: excluded)
    }

    private static func splitPrefix(_ value: String) -> (String, Int?) {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? Int(parts[1]) : nil)
    }
}

/// IPv4 address helpers.
public enum IPv4 {
    public static func isAddress(_ value: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, value, &addr) == 1
    }

    public static func value(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// True for contiguous netmasks such as 255.255.255.0.
    public static func isNetmask(_ text: String) -> Bool {
        guard let mask = value(text), mask != 0 else { return text == "0.0.0.0" }
        let inverted = ~mask
        return inverted & (inverted &+ 1) == 0
    }
}

/// IPv6 address helpers.
public enum IPv6 {
    public static func isAddress(_ value: String) -> Bool {
        var addr = in6_addr()
        return inet_pton(AF_INET6, value, &addr) == 1
    }
}

/// Builds the client's `IV_*` peer-info string sent inside key_method_2.
public enum PeerInfo {
    public static let supportedCiphers = [
        "AES-256-GCM", "AES-128-GCM", "CHACHA20-POLY1305",
    ]

    /// IV_PROTO bits (OpenVPN `ssl.h`): DATA_V2 (1<<1), REQUEST_PUSH (1<<2),
    /// TLS_KEY_EXPORT (1<<3), AUTH_PENDING_KW (1<<4), CC_EXIT_NOTIFY (1<<7),
    /// AUTH_FAIL_TEMP (1<<8), DYN_TLS_CRYPT (1<<9), DATA_EPOCH (1<<10) and
    /// DNS_OPTION_V2 (1<<11). PUSH_UPDATE (1<<12) is not announced: this
    /// client does not apply option updates mid-session.
    public static let protocolBits = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4)
        | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11)

    public static func build(platform: String = "mac", ciphers: [String] = supportedCiphers,
                             protocolBits: Int = protocolBits) -> String {
        let lines = [
            "IV_VER=2.7.6",
            "IV_PLAT=\(platform)",
            "IV_TCPNL=1",
            "IV_MTU=1600",
            "IV_NCP=2",
            "IV_PROTO=\(protocolBits)",
            "IV_CIPHERS=\(ciphers.joined(separator: ":"))",
            "IV_LZO_STUB=1",
            "IV_COMP_STUB=1",
            "IV_COMP_STUBv2=1",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The `key_method_2` options string our client advertises (the OCC string).
public enum OptionsString {
    public static func build(profile: OVPNProfile, transport activeTransport: OVPNProfile.Transport? = nil) -> String {
        let transport: String
        switch activeTransport ?? profile.transport {
        case .udp: transport = "UDPv4"
        case .tcp: transport = "TCPv4_CLIENT"
        }
        var parts = [
            "V4",
            "dev-type \(profile.device.rawValue)",
            "link-mtu 1550",
            "tun-mtu 1500",
            "proto \(transport)",
            "cipher \(profile.cipher.rawValue)",
            "keysize \(keySize(profile.cipher))",
            "key-method 2",
            "tls-client",
        ]
        if let digest = profile.digest {
            parts.insert("auth \(digest.rawValue)", at: 5)
        }
        return parts.joined(separator: ",")
    }

    static func keySize(_ cipher: OVPNProfile.Cipher) -> Int {
        switch cipher {
        case .aes128CBC, .aes128GCM: return 128
        case .aes256CBC, .aes256GCM, .chacha20Poly1305: return 256
        }
    }
}
