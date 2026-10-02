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

/// Spec-aware parser for OpenVPN `.ovpn` configuration files.
///
/// Handles:
/// - `directive value` lines, case-insensitive directive names
/// - `#` and `;` comments at the start of a token, double/single quotes and
///   backslash escapes, exactly like OpenVPN's `parse_line`
/// - inline blocks `<ca>`, `<cert>`, `<key>`, `<extra-certs>`, `<tls-auth>`,
///   `<tls-crypt>`, `<tls-crypt-v2>`, `<auth-user-pass>`, `<connection>`
///
/// Unknown directives are preserved verbatim in `profile.rawDirectives`.
/// Unsupported features are reported in `profile.issues`. File references
/// (`ca ca.crt`) must be inlined first with `OVPNProfileInliner`.
public struct OVPNParser: Sendable {
    public init() {}

    /// A remote before defaults (`port`, `proto`) are applied.
    private struct PendingRemote {
        var host: String
        var port: Int?
        var transport: OVPNProfile.Transport?
        var family: OVPNProfile.AddressFamily?
    }

    private struct State {
        var remotes: [PendingRemote] = []
        var defaultPort: Int?
        var defaultFamily: OVPNProfile.AddressFamily?
    }

    public func parse(_ text: String) throws -> OVPNProfile {
        var profile = OVPNProfile()
        var state = State()

        let lines = text.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if let block = try parseInlineBlock(lines: lines, at: index) {
                applyInlineBlock(block.name, content: block.content, to: &profile, state: &state)
                index = block.endIndex + 1
                continue
            }

            index += 1

            let tokens = Self.tokenize(line)
            guard let directive = tokens.first else { continue }
            let args = Array(tokens.dropFirst())

            apply(directive: directive, args: args, to: &profile, state: &state)
        }

        profile.remotes = state.remotes.map { pending in
            OVPNProfile.Remote(
                host: pending.host,
                port: pending.port ?? state.defaultPort ?? 1194,
                transport: pending.transport,
                family: pending.family ?? (pending.transport == nil ? state.defaultFamily : nil)
            )
        }
        validate(&profile)
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
            if candidate.lowercased() == "</\(name)>" {
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

    private func applyInlineBlock(_ name: String, content: String, to profile: inout OVPNProfile, state: inout State) {
        switch name {
        case "ca": profile.caPEM = content
        case "cert": profile.certPEM = content
        case "key": profile.keyPEM = content
        case "extra-certs": profile.extraCertsPEM = content
        case "tls-auth":
            profile.tlsAuthPEM = content
            profile.tlsAuthKey = PEMKeyExtractor.extractKey(from: content)
        case "tls-crypt":
            profile.tlsCryptPEM = content
            profile.tlsCryptKey = PEMKeyExtractor.extractKey(from: content)
        case "tls-crypt-v2":
            profile.tlsCryptV2PEM = content
        case "auth-user-pass":
            let lines = content.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
                .filter { !$0.isEmpty }
            profile.requiresAuthUserPass = true
            profile.authUserPass = OVPNProfile.AuthUserPass(
                username: lines.first,
                password: lines.count > 1 ? lines[1] : nil
            )
        case "connection":
            parseConnectionBlock(content, state: &state)
        case "dh", "secret", "pkcs12":
            profile.rawDirectives[name, default: []].append("[inline]")
        default:
            break
        }
    }

    /// A `<connection>` block is a connection entry with its own remote,
    /// protocol and port; each remote inside becomes one profile remote.
    private func parseConnectionBlock(_ content: String, state: inout State) {
        var transport: OVPNProfile.Transport?
        var family: OVPNProfile.AddressFamily?
        var port: Int?
        var remotes: [PendingRemote] = []
        for line in content.components(separatedBy: .newlines) {
            let tokens = Self.tokenize(line)
            guard let directive = tokens.first?.lowercased() else { continue }
            let args = Array(tokens.dropFirst())
            switch directive {
            case "remote":
                if let remote = parseRemote(args) { remotes.append(remote) }
            case "proto":
                if let parsed = args.first.flatMap(Self.parseProto) {
                    transport = parsed.transport
                    family = parsed.family
                }
            case "port", "rport":
                port = args.first.flatMap(Int.init)
            default:
                break
            }
        }
        for var remote in remotes {
            remote.port = remote.port ?? port
            if remote.transport == nil {
                remote.transport = transport
                remote.family = remote.family ?? family
            }
            state.remotes.append(remote)
        }
    }

    // MARK: - Directives

    private func apply(directive raw: String, args: [String], to profile: inout OVPNProfile, state: inout State) {
        let directive = raw.lowercased()

        switch directive {
        case "remote":
            guard let remote = parseRemote(args) else {
                profile.issues.append(.init(.warning, "Ignoring malformed remote: \(args.joined(separator: " "))"))
                return
            }
            state.remotes.append(remote)

        case "port", "rport":
            if let port = args.first.flatMap(Int.init), (1...65535).contains(port) {
                state.defaultPort = port
            }

        case "remote-random":
            profile.remoteRandom = true

        case "proto":
            guard let value = args.first?.lowercased() else { return }
            if let parsed = Self.parseProto(value) {
                profile.transport = parsed.transport
                state.defaultFamily = parsed.family
            } else {
                profile.issues.append(.init(.error, "Unsupported protocol '\(value)' (only UDP and TCP client modes are supported)."))
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "dev", "dev-type":
            let value = args.first?.lowercased() ?? ""
            if value.hasPrefix("tap") {
                profile.device = .tap
            } else if value.hasPrefix("tun") {
                profile.device = .tun
            } else {
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "cipher":
            if let cipher = args.first.flatMap(OVPNProfile.Cipher.init(name:)) {
                profile.cipher = cipher
                profile.cipherSpecified = true
            } else {
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "data-ciphers", "ncp-ciphers":
            let names = (args.first ?? "").split(separator: ":").map(String.init)
            profile.dataCiphers = names.compactMap(OVPNProfile.Cipher.init(name:))
            let unsupported = names.filter { OVPNProfile.Cipher(name: $0) == nil && !$0.hasPrefix("?") }
            if !unsupported.isEmpty {
                profile.issues.append(.init(.warning, "Ignoring unsupported data ciphers: \(unsupported.joined(separator: ", "))."))
            }

        case "auth":
            if let digest = args.first.flatMap(OVPNProfile.Digest.init(name:)) {
                profile.digest = digest
            } else {
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "tls-auth", "tls-crypt", "tls-crypt-v2", "ca", "cert", "key", "extra-certs":
            // Inline blocks carry the content; the directive form names a
            // file (inlined at import) or `[inline]`, optionally with the
            // tls-auth key direction.
            if directive == "tls-auth", args.count > 1, let direction = Int(args[1]) {
                profile.keyDirection = direction
            }
            if let file = args.first, file != "[inline]" {
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "key-direction":
            if let direction = args.first.flatMap(Int.init) {
                profile.keyDirection = direction
            }

        case "tls-version-min":
            profile.tlsVersionMin = args.joined(separator: " ")

        case "tls-cipher":
            profile.tlsCipher = args.first

        case "tls-ciphersuites":
            profile.tlsCiphersuites = args.first

        case "remote-cert-tls":
            if let mode = OVPNProfile.RemoteCertTLS(rawValue: args.first?.lowercased() ?? "") {
                profile.remoteCertTLS = mode
            }

        case "verify-x509-name":
            // OpenVPN's default type is `subject` (the full subject DN).
            if args.count >= 2, let kind = OVPNProfile.X509NameCheck.Kind(rawValue: args[1].lowercased()) {
                profile.x509NameCheck = .verifyName(args[0], kind)
            } else if let name = args.first {
                profile.x509NameCheck = .verifyName(name, .subject)
            }

        case "auth-user-pass":
            profile.requiresAuthUserPass = true
            if let file = args.first, file != "[inline]" {
                appendRaw(directive: raw, args: args, to: &profile)
            }

        case "askpass":
            profile.askPass = true

        case "keepalive":
            if args.count >= 2, let ping = Int(args[0]), let restart = Int(args[1]) {
                profile.pingSeconds = ping
                profile.pingRestartSeconds = restart
            }

        case "ping":
            profile.pingSeconds = args.first.flatMap(Int.init)

        case "ping-restart":
            profile.pingRestartSeconds = args.first.flatMap(Int.init)

        case "reneg-sec":
            profile.renegSeconds = args.first.flatMap(Int.init)

        case "hand-window":
            profile.handWindow = args.first.flatMap(Int.init)

        case "tun-mtu":
            profile.tunMTU = args.first.flatMap(Int.init)

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

    private func parseRemote(_ args: [String]) -> PendingRemote? {
        guard let host = args.first, !host.isEmpty else { return nil }
        var remote = PendingRemote(host: host)
        if args.count > 1 {
            guard let port = Int(args[1]), (1...65535).contains(port) else { return nil }
            remote.port = port
        }
        if args.count > 2, let parsed = Self.parseProto(args[2].lowercased()) {
            remote.transport = parsed.transport
            remote.family = parsed.family
        }
        return remote
    }

    /// `udp`, `udp4`, `udp6`, `tcp`, `tcp4`, `tcp6`, `tcp-client`,
    /// `tcp4-client`, `tcp6-client`. Server modes are not client protocols.
    static func parseProto(_ value: String) -> (transport: OVPNProfile.Transport, family: OVPNProfile.AddressFamily?)? {
        var name = value.lowercased()
        if name.hasSuffix("-client") {
            name.removeLast("-client".count)
        }
        guard !name.hasSuffix("-server") else { return nil }
        let transport: OVPNProfile.Transport
        if name.hasPrefix("udp") {
            transport = .udp
        } else if name.hasPrefix("tcp") {
            transport = .tcp
        } else {
            return nil
        }
        switch name.dropFirst(3) {
        case "": return (transport, nil)
        case "4": return (transport, .ipv4)
        case "6": return (transport, .ipv6)
        default: return nil
        }
    }

    private func appendRaw(directive: String, args: [String], to profile: inout OVPNProfile) {
        let key = directive.lowercased()
        let joined = args.joined(separator: " ")
        profile.rawDirectives[key, default: []].append(joined)
    }

    // MARK: - Validation

    private func validate(_ profile: inout OVPNProfile) {
        func error(_ message: String) { profile.issues.append(.init(.error, message)) }
        func warning(_ message: String) { profile.issues.append(.init(.warning, message)) }
        let raw = profile.rawDirectives

        if profile.remotes.isEmpty {
            error("The profile has no remote server.")
        }
        if profile.caPEM == nil {
            if let file = raw["ca"]?.first {
                error("The CA certificate file '\(file)' is referenced but not embedded. Import the profile together with its files.")
            } else {
                error("The profile has no CA certificate (<ca>).")
            }
        }
        let embedded: [(String, String, Bool)] = [
            ("cert", "<cert>", profile.certPEM != nil),
            ("key", "<key>", profile.keyPEM != nil),
            ("tls-auth", "<tls-auth>", profile.tlsAuthPEM != nil),
            ("tls-crypt", "<tls-crypt>", profile.tlsCryptPEM != nil),
            ("tls-crypt-v2", "<tls-crypt-v2>", profile.tlsCryptV2PEM != nil),
            ("extra-certs", "<extra-certs>", profile.extraCertsPEM != nil),
        ]
        for (directive, tag, present) in embedded where !present {
            if let file = raw[directive]?.first {
                error("The \(tag) file '\(file.split(separator: " ").first ?? "")' is referenced but not embedded. Import the profile together with its files.")
            }
        }
        if (profile.certPEM == nil) != (profile.keyPEM == nil), raw["cert"] == nil, raw["key"] == nil {
            error("The profile has a client certificate without a private key, or a key without a certificate.")
        }
        if profile.device == .tap {
            error("Bridged (dev tap) profiles are not supported; only routed tun profiles are.")
        }
        if raw["secret"] != nil {
            error("Static-key (secret) profiles are not supported; a TLS profile is required.")
        }
        for directive in ["pkcs12", "pkcs11-id", "cryptoapicert", "management-external-key", "management-external-cert"] where raw[directive] != nil {
            error("'\(directive)' is not supported; embed the certificate and key as <cert> and <key>.")
        }
        for directive in ["http-proxy", "socks-proxy"] where raw[directive] != nil {
            error("'\(directive)' is not supported.")
        }
        if raw["fragment"] != nil {
            error("'fragment' is not supported.")
        }
        if raw["mode"] != nil || raw["tls-server"] != nil || raw["server"] != nil {
            error("This is a server configuration, not a client profile.")
        }
        let compressionStubs: Set<String> = ["stub", "stub-v2", "no", "migrate"]
        if let values = raw["compress"], values.contains(where: { !$0.isEmpty && !compressionStubs.contains($0.lowercased()) }) {
            warning("Compression is not supported; the connection only works if the server disables it.")
        }
        if let values = raw["comp-lzo"], values.contains(where: { $0.lowercased() != "no" }) {
            warning("LZO compression is not supported; the connection only works if the server disables it.")
        }
        if let cipher = raw["cipher"]?.first {
            warning("Unsupported cipher '\(cipher)'; the server must negotiate one of \(PeerInfo.supportedCiphers.joined(separator: ", ")).")
        }
    }

    // MARK: - Tokenizing

    /// Splits a config line into parameters with OpenVPN's `parse_line`
    /// rules: `#`/`;` start a comment only at the beginning of a token,
    /// double quotes allow backslash escapes, single quotes are literal.
    public static func tokenize(_ line: String) -> [String] {
        enum Mode { case initial, unquoted, doubleQuoted, singleQuoted }
        var tokens: [String] = []
        var current = ""
        var mode = Mode.initial
        var backslash = false

        func finish() {
            tokens.append(current)
            current = ""
            mode = .initial
        }

        for char in line {
            if !backslash, char == "\\", mode != .singleQuoted {
                backslash = true
                continue
            }
            let escaped = backslash
            backslash = false
            switch mode {
            case .initial:
                if char == " " || char == "\t" || char == "\r" { continue }
                if !escaped, char == "#" || char == ";" { return tokens }
                if !escaped, char == "\"" {
                    mode = .doubleQuoted
                } else if !escaped, char == "'" {
                    mode = .singleQuoted
                } else {
                    current.append(char)
                    mode = .unquoted
                }
            case .unquoted:
                if !escaped, char == " " || char == "\t" || char == "\r" {
                    finish()
                } else {
                    current.append(char)
                }
            case .doubleQuoted:
                if !escaped, char == "\"" {
                    finish()
                } else {
                    current.append(char)
                }
            case .singleQuoted:
                if char == "'" {
                    finish()
                } else {
                    current.append(char)
                }
            }
        }
        if mode != .initial {
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
