import Foundation

public enum PushParseError: Error, Sendable, Equatable {
    case malformedMessage
}

/// The options a server pushes in its `PUSH_REPLY` message.
public struct PushedOptions: Sendable, Equatable {
    public var peerID: UInt32?
    public var cipher: OVPNProfile.Cipher?
    public var digest: OVPNProfile.Digest?
    public var useTLSKeyExport: Bool
    public var pingSeconds: Int?
    public var pingRestartSeconds: Int?
    public var renegSeconds: Int?
    public var ifconfigLocal: String?
    public var ifconfigRemote: String?
    public var routeGateway: String?
    public var topology: String?
    public var dnsServers: [String]
    public var aeadEpoch: Bool
    /// Raw options, for the policy engine (routes, DNS, redirect-gateway...).
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
        self.raw = raw
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
    /// `PUSH_REPLY,opt1,opt2,...` — entries with spaces/commas are
    /// base64-encoded as `base64,<data>`.
    public static func parseReply(_ payload: Data) throws -> PushMessage {
        // Control-channel string messages carry a trailing NUL; it corrupts
        // the LAST option's value (e.g. a trailing "cipher AES-256-GCM").
        let text = String(decoding: payload, as: UTF8.self)
            .replacingOccurrences(of: "\0", with: "")
        guard text.hasPrefix("PUSH_REPLY,") else {
            return classify(text)
        }

        var options: [String] = []
        let cursor = text.index(text.startIndex, offsetBy: "PUSH_REPLY,".count)
        let parts = text[cursor...].split(separator: ",", omittingEmptySubsequences: false)

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
            } else if trimmed.hasPrefix("base64,") {
                let encoded = String(trimmed.dropFirst("base64,".count))
                if let decoded = Data(base64Encoded: encoded),
                   let decodedText = String(data: decoded, encoding: .utf8) {
                    options.append(decodedText)
                }
            } else {
                options.append(trimmed)
            }
        }

        var pushed = PushedOptions(raw: options)
        for option in options {
            let tokens = option.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = tokens.first else { continue }
            let value = tokens.count > 1 ? String(tokens.dropFirst().joined(separator: " ")) : ""

            switch name {
            case "peer-id":
                pushed.peerID = UInt32(value)
            case "cipher":
                pushed.cipher = OVPNProfile.Cipher(rawValue: value.uppercased())
            case "auth":
                pushed.digest = OVPNProfile.Digest(rawValue: value.uppercased())
            case "key-derivation":
                pushed.useTLSKeyExport = (value == "tls-ekm")
            case "protocol-flags":
                if value.contains("tls-ekm") { pushed.useTLSKeyExport = true }
                if value.contains("aead-epoch") { pushed.aeadEpoch = true }
            case "ping":
                pushed.pingSeconds = Int(value)
            case "ping-restart":
                pushed.pingRestartSeconds = Int(value)
            case "reneg-sec":
                pushed.renegSeconds = Int(value)
            case "ifconfig":
                let addresses = option.split(separator: " ").map(String.init)
                if addresses.count >= 2 {
                    pushed.ifconfigLocal = addresses[1]
                    pushed.ifconfigRemote = addresses[2]
                }
            case "route-gateway":
                pushed.routeGateway = value
            case "topology":
                pushed.topology = value
            case "dns":
                pushed.dnsServers = tokens.dropFirst().map(String.init)
            case "dhcp-option":
                if tokens.count >= 3, tokens[1].uppercased() == "DNS" {
                    pushed.dnsServers.append(String(tokens[2]))
                }
            default:
                break
            }
        }
        return .reply(pushed)
    }

    private static func classify(_ text: String) -> PushMessage {
        if text.hasPrefix("AUTH_FAILED") {
            let detail = text.dropFirst("AUTH_FAILED,".count)
            return .authFailed(String(detail))
        }
        if text.hasPrefix("RESTART") {
            return .restart(String(text.dropFirst("RESTART".count)))
        }
        if text == "HALT" {
            return .halt
        }
        if text.hasPrefix("INFO") {
            return .info(text)
        }
        return .other(text)
    }
}

/// Builds the client's `IV_*` peer-info string sent inside key_method_2.
public enum PeerInfo {
    public static let supportedCiphers = [
        "AES-256-GCM", "AES-128-GCM", "CHACHA20-POLY1305",
    ]

    /// IV_PROTO bits matching the official 2.7 client (8094): DATA_V2,
    /// REQUEST_PUSH, TLS_KEY_EXPORT, AUTH_PENDING_KW, CC_EXIT,
    /// AUTH_FAIL_TEMP, DYN_TLS_CRYPT and the newer protocol bits.
    public static let protocolBits = 8094

    public static func build(platform: String = "mac") -> String {
        let lines = [
            "IV_VER=2.7.6",
            "IV_PLAT=\(platform)",
            "IV_TCPNL=1",
            "IV_MTU=1600",
            "IV_NCP=2",
            "IV_PROTO=\(protocolBits)",
            "IV_CIPHERS=\(supportedCiphers.joined(separator: ":"))",
            "IV_LZO_STUB=1",
            "IV_COMP_STUB=1",
            "IV_COMP_STUBv2=1",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The `key_method_2` options string our client advertises (the OCC string).
public enum OptionsString {
    public static func build(profile: OVPNProfile) -> String {
        let transport: String
        switch profile.transport {
        case .udp: transport = "UDPv4"
        case .tcp: transport = "TCPv4"
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
