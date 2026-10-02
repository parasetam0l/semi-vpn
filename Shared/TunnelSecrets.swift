import Foundation

/// Reads the profile and credentials the app hands to the tunnel provider.
public enum TunnelSecrets {
    /// Provider-configuration keys for connect-time credentials.
    public static let usernameKey = "username"
    public static let passwordKey = "password"
    public static let keyPassphraseKey = "keyPassphrase"

    public struct Credentials: Equatable {
        public var username: String?
        public var password: String?
        public var keyPassphrase: String?

        public init(username: String? = nil, password: String? = nil, keyPassphrase: String? = nil) {
            self.username = username
            self.password = password
            self.keyPassphrase = keyPassphrase
        }
    }

    public static func profileText(from configuration: [String: Any]) -> String? {
        configuration[SharedConfig.profileKey] as? String
    }

    public static func credentials(from configuration: [String: Any]) -> Credentials {
        Credentials(
            username: configuration[usernameKey] as? String,
            password: configuration[passwordKey] as? String,
            keyPassphrase: configuration[keyPassphraseKey] as? String
        )
    }
}
