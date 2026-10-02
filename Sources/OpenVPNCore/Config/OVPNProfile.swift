import Foundation

/// An OpenVPN profile parsed from a .ovpn configuration file.
public struct OVPNProfile: Sendable {
    public struct Remote: Sendable, Equatable {
        public var host: String
        public var port: Int
        /// Per-remote protocol (`remote host port proto`, or the `proto` of
        /// a `<connection>` block); nil uses the profile's `proto`.
        public var transport: Transport?
        /// Address family restriction from `udp4`/`tcp6`-style protocols.
        public var family: AddressFamily?

        public init(host: String, port: Int, transport: Transport? = nil, family: AddressFamily? = nil) {
            self.host = host
            self.port = port
            self.transport = transport
            self.family = family
        }
    }

    public enum Transport: String, Sendable {
        case udp
        case tcp
    }

    public enum AddressFamily: String, Sendable {
        case ipv4
        case ipv6
    }

    public enum Device: String, Sendable {
        case tun
        case tap
    }

    public enum Cipher: String, Sendable, CaseIterable {
        case aes256CBC = "AES-256-CBC"
        case aes128CBC = "AES-128-CBC"
        case aes256GCM = "AES-256-GCM"
        case aes128GCM = "AES-128-GCM"
        case chacha20Poly1305 = "CHACHA20-POLY1305"

        /// Case-insensitive lookup (`cipher aes-256-gcm` is valid OpenVPN).
        public init?(name: String) {
            self.init(rawValue: name.uppercased())
        }

        public var isAEAD: Bool {
            switch self {
            case .aes256GCM, .aes128GCM, .chacha20Poly1305: return true
            case .aes256CBC, .aes128CBC: return false
            }
        }
    }

    public enum Digest: String, Sendable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha384 = "SHA384"
        case sha512 = "SHA512"

        /// Case-insensitive lookup; accepts `SHA-256` style spellings.
        public init?(name: String) {
            self.init(rawValue: name.uppercased().replacingOccurrences(of: "-", with: ""))
        }
    }

    public enum X509NameCheck: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case name
            case namePrefix = "name-prefix"
            case subject
        }

        case verifyName(String, Kind)
    }

    public enum RemoteCertTLS: String, Sendable {
        case server
        case client
    }

    public struct AuthUserPass: Sendable, Equatable {
        public var username: String?
        public var password: String?

        public init(username: String? = nil, password: String? = nil) {
            self.username = username
            self.password = password
        }
    }

    /// A problem found while parsing: unsupported features and missing
    /// material. Errors make the profile unusable; warnings may still work.
    public struct Issue: Sendable, Equatable, CustomStringConvertible {
        public enum Severity: Sendable, Equatable {
            case error
            case warning
        }

        public var severity: Severity
        public var message: String

        public init(_ severity: Severity, _ message: String) {
            self.severity = severity
            self.message = message
        }

        public var description: String { message }
    }

    // MARK: - Core connection settings

    public var remotes: [Remote]
    public var transport: Transport
    public var device: Device
    /// `remote-random`: try the remotes in random order.
    public var remoteRandom: Bool

    // MARK: - Crypto settings

    public var cipher: Cipher
    /// True when the profile has an explicit (supported) `cipher` directive.
    public var cipherSpecified: Bool
    public var digest: Digest?
    /// `data-ciphers` / `ncp-ciphers` (supported entries only).
    public var dataCiphers: [Cipher]
    public var tlsAuthKey: Data?
    public var tlsCryptKey: Data?
    public var keyDirection: Int?
    public var tlsVersionMin: String?

    // MARK: - PKI

    public var caPEM: String?
    public var certPEM: String?
    public var keyPEM: String?
    /// `extra-certs`: intermediate certificates sent with the client cert.
    public var extraCertsPEM: String?
    public var tlsAuthPEM: String?
    public var tlsCryptPEM: String?
    public var tlsCryptV2PEM: String?
    /// `askpass`: the private key is encrypted and needs a passphrase.
    public var askPass: Bool
    /// The private-key passphrase supplied at connect time.
    public var keyPassphrase: String?

    // MARK: - Peer verification

    public var remoteCertTLS: RemoteCertTLS?
    public var x509NameCheck: X509NameCheck?

    // MARK: - Auth

    public var requiresAuthUserPass: Bool
    /// Credentials from an inline `<auth-user-pass>` block, or supplied at
    /// connect time.
    public var authUserPass: AuthUserPass?

    // MARK: - Timers and sizes

    /// `ping` / the first `keepalive` argument (pushed values win).
    public var pingSeconds: Int?
    /// `ping-restart` / the second `keepalive` argument.
    public var pingRestartSeconds: Int?
    /// `reneg-sec`: the client's own renegotiation interval.
    public var renegSeconds: Int?
    /// `hand-window`: seconds allowed for the TLS handshake and push.
    public var handWindow: Int?
    public var tunMTU: Int?

    // MARK: - IPv6 configuration

    public struct RouteIPv6: Sendable, Equatable {
        public var prefix: String
        public var netbits: Int
        public var gateway: String?
        public var metric: Int?

        public init(prefix: String, netbits: Int = 64, gateway: String? = nil, metric: Int? = nil) {
            self.prefix = prefix
            self.netbits = netbits
            self.gateway = gateway
            self.metric = metric
        }
    }

    public var ifconfigIPv6Local: String?
    public var ifconfigIPv6Netbits: Int?
    public var ifconfigIPv6Remote: String?
    public var routesIPv6: [RouteIPv6]
    public var redirectGatewayIPv6: Bool
    public var dnsIPv6Servers: [String]

    // MARK: - Misc

    public var nobind: Bool
    public var persistKey: Bool
    public var persistTun: Bool
    /// `replay-window` from the profile; nil uses the protocol default (64).
    public var replayWindow: Int?
    public var verbosity: Int?
    /// Problems found while parsing (unsupported features, bad values).
    public var issues: [Issue]
    /// Every unrecognized or pass-through directive, verbatim, for the policy engine.
    public var rawDirectives: [String: [String]]

    public init(
        remotes: [Remote] = [],
        transport: Transport = .udp,
        device: Device = .tun,
        remoteRandom: Bool = false,
        cipher: Cipher = .aes256CBC,
        cipherSpecified: Bool = false,
        digest: Digest? = nil,
        dataCiphers: [Cipher] = [],
        tlsAuthKey: Data? = nil,
        tlsCryptKey: Data? = nil,
        keyDirection: Int? = nil,
        tlsVersionMin: String? = nil,
        caPEM: String? = nil,
        certPEM: String? = nil,
        keyPEM: String? = nil,
        extraCertsPEM: String? = nil,
        tlsAuthPEM: String? = nil,
        tlsCryptPEM: String? = nil,
        tlsCryptV2PEM: String? = nil,
        askPass: Bool = false,
        keyPassphrase: String? = nil,
        remoteCertTLS: RemoteCertTLS? = nil,
        x509NameCheck: X509NameCheck? = nil,
        requiresAuthUserPass: Bool = false,
        authUserPass: AuthUserPass? = nil,
        pingSeconds: Int? = nil,
        pingRestartSeconds: Int? = nil,
        renegSeconds: Int? = nil,
        handWindow: Int? = nil,
        tunMTU: Int? = nil,
        ifconfigIPv6Local: String? = nil,
        ifconfigIPv6Netbits: Int? = nil,
        ifconfigIPv6Remote: String? = nil,
        routesIPv6: [RouteIPv6] = [],
        redirectGatewayIPv6: Bool = false,
        dnsIPv6Servers: [String] = [],
        nobind: Bool = false,
        persistKey: Bool = false,
        persistTun: Bool = false,
        replayWindow: Int? = nil,
        verbosity: Int? = nil,
        issues: [Issue] = [],
        rawDirectives: [String: [String]] = [:]
    ) {
        self.remotes = remotes
        self.transport = transport
        self.device = device
        self.remoteRandom = remoteRandom
        self.cipher = cipher
        self.cipherSpecified = cipherSpecified
        self.digest = digest
        self.dataCiphers = dataCiphers
        self.tlsAuthKey = tlsAuthKey
        self.tlsCryptKey = tlsCryptKey
        self.keyDirection = keyDirection
        self.tlsVersionMin = tlsVersionMin
        self.caPEM = caPEM
        self.certPEM = certPEM
        self.keyPEM = keyPEM
        self.extraCertsPEM = extraCertsPEM
        self.tlsAuthPEM = tlsAuthPEM
        self.tlsCryptPEM = tlsCryptPEM
        self.tlsCryptV2PEM = tlsCryptV2PEM
        self.askPass = askPass
        self.keyPassphrase = keyPassphrase
        self.remoteCertTLS = remoteCertTLS
        self.x509NameCheck = x509NameCheck
        self.requiresAuthUserPass = requiresAuthUserPass
        self.authUserPass = authUserPass
        self.pingSeconds = pingSeconds
        self.pingRestartSeconds = pingRestartSeconds
        self.renegSeconds = renegSeconds
        self.handWindow = handWindow
        self.tunMTU = tunMTU
        self.ifconfigIPv6Local = ifconfigIPv6Local
        self.ifconfigIPv6Netbits = ifconfigIPv6Netbits
        self.ifconfigIPv6Remote = ifconfigIPv6Remote
        self.routesIPv6 = routesIPv6
        self.redirectGatewayIPv6 = redirectGatewayIPv6
        self.dnsIPv6Servers = dnsIPv6Servers
        self.nobind = nobind
        self.persistKey = persistKey
        self.persistTun = persistTun
        self.replayWindow = replayWindow
        self.verbosity = verbosity
        self.issues = issues
        self.rawDirectives = rawDirectives
    }

    /// The `auth` digest in effect: OpenVPN defaults to SHA1 when the profile
    /// has no `auth` directive (used by tls-auth and the CBC data channel).
    public var effectiveDigest: Digest { digest ?? .sha1 }

    /// The first remote, or nil if none configured.
    public var primaryRemote: Remote? { remotes.first }

    /// The transport used for a remote.
    public func transport(for remote: Remote) -> Transport {
        remote.transport ?? transport
    }

    /// Ciphers announced in `IV_CIPHERS`: `data-ciphers` (or the OpenVPN
    /// default list) plus the profile's `cipher`, which OpenVPN 2.5+ also
    /// appends for compatibility with servers that only know it.
    public var announcedCiphers: [String] {
        var ciphers = dataCiphers.isEmpty ? PeerInfo.supportedCiphers : dataCiphers.map(\.rawValue)
        if cipherSpecified, !ciphers.contains(cipher.rawValue) {
            ciphers.append(cipher.rawValue)
        }
        return ciphers
    }

    /// Issues that make the profile impossible to connect with.
    public var fatalIssues: [Issue] {
        issues.filter { $0.severity == .error }
    }
}
