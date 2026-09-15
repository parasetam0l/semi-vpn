import Foundation

/// An OpenVPN profile parsed from a .ovpn configuration file.
public struct OVPNProfile: Sendable {
    public struct Remote: Sendable, Equatable {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public enum Transport: String, Sendable {
        case udp
        case tcp
    }

    public enum Device: String, Sendable {
        case tun
        case tap
    }

    public enum Cipher: String, Sendable {
        case aes256CBC = "AES-256-CBC"
        case aes128CBC = "AES-128-CBC"
        case aes256GCM = "AES-256-GCM"
        case aes128GCM = "AES-128-GCM"
        case chacha20Poly1305 = "CHACHA20-POLY1305"

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

    public struct AuthUserPass: Sendable {
        public var username: String?
        public var password: String?

        public init(username: String? = nil, password: String? = nil) {
            self.username = username
            self.password = password
        }
    }

    // MARK: - Core connection settings

    public var remotes: [Remote]
    public var transport: Transport
    public var device: Device

    // MARK: - Crypto settings

    public var cipher: Cipher
    public var digest: Digest?
    public var tlsAuthKey: Data?
    public var tlsCryptKey: Data?
    public var keyDirection: Int?
    public var tlsVersionMin: String?

    // MARK: - PKI

    public var caPEM: String?
    public var certPEM: String?
    public var keyPEM: String?
    public var tlsAuthPEM: String?
    public var tlsCryptPEM: String?
    public var tlsCryptV2PEM: String?

    // MARK: - Peer verification

    public var remoteCertTLS: RemoteCertTLS?
    public var x509NameCheck: X509NameCheck?

    // MARK: - Auth

    public var requiresAuthUserPass: Bool
    public var authUserPass: AuthUserPass?

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
    /// Every unrecognized or pass-through directive, verbatim, for the policy engine.
    public var rawDirectives: [String: [String]]

    public init(
        remotes: [Remote] = [],
        transport: Transport = .udp,
        device: Device = .tun,
        cipher: Cipher = .aes256CBC,
        digest: Digest? = nil,
        tlsAuthKey: Data? = nil,
        tlsCryptKey: Data? = nil,
        keyDirection: Int? = nil,
        tlsVersionMin: String? = nil,
        caPEM: String? = nil,
        certPEM: String? = nil,
        keyPEM: String? = nil,
        tlsAuthPEM: String? = nil,
        tlsCryptPEM: String? = nil,
        tlsCryptV2PEM: String? = nil,
        remoteCertTLS: RemoteCertTLS? = nil,
        x509NameCheck: X509NameCheck? = nil,
        requiresAuthUserPass: Bool = false,
        authUserPass: AuthUserPass? = nil,
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
        rawDirectives: [String: [String]] = [:]
    ) {
        self.remotes = remotes
        self.transport = transport
        self.device = device
        self.cipher = cipher
        self.digest = digest
        self.tlsAuthKey = tlsAuthKey
        self.tlsCryptKey = tlsCryptKey
        self.keyDirection = keyDirection
        self.tlsVersionMin = tlsVersionMin
        self.caPEM = caPEM
        self.certPEM = certPEM
        self.keyPEM = keyPEM
        self.tlsAuthPEM = tlsAuthPEM
        self.tlsCryptPEM = tlsCryptPEM
        self.tlsCryptV2PEM = tlsCryptV2PEM
        self.remoteCertTLS = remoteCertTLS
        self.x509NameCheck = x509NameCheck
        self.requiresAuthUserPass = requiresAuthUserPass
        self.authUserPass = authUserPass
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
        self.rawDirectives = rawDirectives
    }

    /// The first remote, or nil if none configured.
    public var primaryRemote: Remote? { remotes.first }
}
