import Foundation

public enum OVPNParseError: Error, Equatable, Sendable {
    case invalidText
    case invalidRemote(String)
    case invalidPort(String)
    case invalidCipher(String)
    case invalidDigest(String)
    case invalidKeyDirection(String)
    case unclosedInlineBlock(String)
    case unexpectedToken(String)
}

/// Minimal, spec-aware parser for OpenVPN `.ovpn` configuration files.
///
/// Handles:
/// - `directive value` lines, case-insensitive directive names
/// - `#` and `;` comments
/// - inline PEM blocks `<ca> ... </ca>`, `<cert>`, `<key>`, `<tls-auth>`, `<tls-crypt>`
/// - quoted values (e.g. `remote "host" 1194`)
///
/// Unknown directives are preserved verbatim in `profile.rawDirectives`
/// so the policy engine can pass them through without losing information.
public struct OVPNParser: Sendable {
    public init() {}

    public func parse(_ text: String) throws -> OVPNProfile {
        var profile = OVPNProfile()

        let lines = text.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if let block = try parseInlineBlock(lines: lines, at: index) {
                applyInlineBlock(block.name, content: block.content, to: &profile)
                index = block.endIndex + 1
                continue
            }

            index += 1

            let stripped = stripComment(line)
            guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let tokens = tokenize(stripped)
            guard let directive = tokens.first else { continue }
            let args = Array(tokens.dropFirst())

            apply(directive: directive, args: args, to: &profile)
        }

        return profile
    }

    // MARK: - Inline blocks

    private struct InlineBlock {
        var name: String
        var content: String
        var endIndex: Int
    }

    private func parseInlineBlock(lines: [String], at index: Int) throws -> InlineBlock? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("<"), line.hasSuffix(">") else { return nil }
        let name = String(line.dropFirst().dropLast()).lowercased()
        guard !name.isEmpty, !name.hasPrefix("/") else { return nil }

        var content: [String] = []
        var cursor = index + 1
        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
            if candidate == "</\(name)>" {
                return InlineBlock(
                    name: name,
                    content: content.joined(separator: "\n"),
                    endIndex: cursor
                )
            }
            content.append(lines[cursor])
            cursor += 1
        }
        throw OVPNParseError.unclosedInlineBlock(name)
    }

    private func applyInlineBlock(_ name: String, content: String, to profile: inout OVPNProfile) {
        switch name {
        case "ca": profile.caPEM = content
        case "cert": profile.certPEM = content
        case "key": profile.keyPEM = content
        case "tls-auth":
            profile.tlsAuthPEM = content
            profile.tlsAuthKey = PEMKeyExtractor.extractKey(from: content)
        case "tls-crypt":
            profile.tlsCryptPEM = content
            profile.tlsCryptKey = PEMKeyExtractor.extractKey(from: content)
        case "tls-crypt-v2":
            profile.tlsCryptV2PEM = content
        default:
            break
        }
    }

    // MARK: - Directives

    private func apply(directive raw: String, args: [String], to profile: inout OVPNProfile) {
        let directive = raw.lowercased()

        switch directive {
        case "remote":
            guard let host = args.first, !host.isEmpty else {
                appendRaw(directive: raw, args: args, to: &profile)
                return
            }
            let port = args.count > 1 ? (Int(args[1]) ?? 1194) : 1194
            profile.remotes.append(OVPNProfile.Remote(host: host, port: port))

        case "proto":
            if let transport = OVPNProfile.Transport(rawValue: args.first?.lowercased() ?? "") {
                profile.transport = transport
            } else {
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "dev":
            if let device = OVPNProfile.Device(rawValue: args.first?.lowercased() ?? "") {
                profile.device = device
            } else {
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "cipher":
            if let cipher = OVPNProfile.Cipher(rawValue: args.first ?? "") {
                profile.cipher = cipher
            } else {
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "auth":
            if let digest = OVPNProfile.Digest(rawValue: args.first ?? "") {
                profile.digest = digest
            } else {
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "tls-auth", "tls-crypt":
            // Standalone file reference form; key content may come from the
            // inline block instead. Tolerate the argument (file path / 0|1).
            if args.count > 1, let direction = Int(args[1]) {
                profile.keyDirection = direction
            }

        case "key-direction":
            if let direction = args.first.flatMap(Int.init) {
                profile.keyDirection = direction
            }

        case "tls-version-min":
            profile.tlsVersionMin = args.first

        case "remote-cert-tls":
            if let mode = OVPNProfile.RemoteCertTLS(rawValue: args.first?.lowercased() ?? "") {
                profile.remoteCertTLS = mode
            }

        case "verify-x509-name":
            if args.count >= 2, let kind = OVPNProfile.X509NameCheck.Kind(rawValue: args[1].lowercased()) {
                profile.x509NameCheck = .verifyName(args[0], kind)
            } else if let name = args.first {
                profile.x509NameCheck = .verifyName(name, .name)
            }

        case "auth-user-pass":
            profile.requiresAuthUserPass = true

        case "nobind":
            profile.nobind = true

        case "persist-key":
            profile.persistKey = true

        case "persist-tun":
            profile.persistTun = true

        case "replay-window":
            if let window = args.first.flatMap(Int.init) {
                profile.replayWindow = window
            }

        case "ifconfig-ipv6":
            if let first = args.first {
                if first.contains("/") {
                    let parts = first.split(separator: "/", maxSplits: 1).map(String.init)
                    profile.ifconfigIPv6Local = parts[0]
                    profile.ifconfigIPv6Netbits = parts.count > 1 ? Int(parts[1]) : 64
                } else {
                    profile.ifconfigIPv6Local = first
                    profile.ifconfigIPv6Netbits = 64
                }
            }
            if args.count > 1 {
                profile.ifconfigIPv6Remote = args[1]
            }

        case "route-ipv6":
            if let first = args.first {
                var prefix = first
                var netbits = 64
                if first.contains("/") {
                    let parts = first.split(separator: "/", maxSplits: 1).map(String.init)
                    prefix = parts[0]
                    netbits = parts.count > 1 ? (Int(parts[1]) ?? 64) : 64
                }
                let gateway = args.count > 1 ? args[1] : nil
                let metric = args.count > 2 ? Int(args[2]) : nil
                profile.routesIPv6.append(OVPNProfile.RouteIPv6(
                    prefix: prefix,
                    netbits: netbits,
                    gateway: gateway,
                    metric: metric
                ))
            }

        case "redirect-gateway":
            if args.contains(where: { $0.lowercased() == "ipv6" }) {
                profile.redirectGatewayIPv6 = true
            }
            appendRaw(directive: raw, args: args, to: &profile)

        case "dhcp-option":
            if args.count >= 2 {
                let optType = args[0].uppercased()
                let optVal = args[1]
                if optType == "DNS6" || (optType == "DNS" && optVal.contains(":")) {
                    profile.dnsIPv6Servers.append(optVal)
                }
            }
            appendRaw(directive: raw, args: args, to: &profile)

        case "verb":
            profile.verbosity = args.first.flatMap(Int.init)

        default:
            appendRaw(directive: raw, args: args, to: &profile)
        }
    }

    private func appendRaw(directive: String, args: [String], to profile: inout OVPNProfile) {
        let key = directive.lowercased()
        let joined = args.joined(separator: " ")
        profile.rawDirectives[key, default: []].append(joined)
    }

    // MARK: - Tokenizing

    private func stripComment(_ line: String) -> String {
        var inQuote = false
        for (i, char) in line.enumerated() {
            if char == "\"" { inQuote.toggle() }
            if (char == "#" || char == ";") && !inQuote {
                return String(line.prefix(i))
            }
        }
        return line
    }

    private func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false

        for char in line {
            switch char {
            case "\"":
                inQuote.toggle()
            case " ", "\t":
                if inQuote {
                    current.append(char)
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            default:
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}

/// Extracts raw key material from inline PEM blocks.
public enum PEMKeyExtractor {
    /// Returns the decoded DER bytes of a PEM block, or nil if the block is
    /// not a valid PEM (the parser tolerates malformed keys at parse time;
    /// validation happens when the connection is established).
    public static func extractKey(from pem: String) -> Data? {
        let lines = pem.components(separatedBy: .newlines)
        var base64Lines: [String] = []
        var inBody = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN") {
                inBody = true
                continue
            }
            if trimmed.hasPrefix("-----END") {
                inBody = false
                continue
            }
            if inBody {
                base64Lines.append(trimmed)
            }
        }

        let joined = base64Lines.joined()
        guard !joined.isEmpty else { return nil }
        return Data(base64Encoded: joined)
    }
}
