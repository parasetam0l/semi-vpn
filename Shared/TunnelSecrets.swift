import Foundation
import Security

/// Hands the profile and its credentials from the app to the tunnel
/// provider.
///
/// The provider is a system extension that runs as root, so it cannot read
/// the user's keychain, and the Network Extension preferences are stored
/// unencrypted on disk. The app therefore passes the profile and credentials
/// in the options of every start it requests (in memory, over the system's
/// IPC). The provider keeps them in a file in its own container, readable
/// by root only, for the starts it gets without options: per-app on-demand
/// and reconnects after sleep. Credentials the user did not ask to remember
/// are not written there, and a rejected password is removed.
public enum TunnelSecrets {
    /// Start-option keys.
    public static let profileTextKey = "profileText"
    public static let usernameKey = "username"
    public static let passwordKey = "password"
    public static let keyPassphraseKey = "keyPassphrase"
    public static let rememberCredentialsKey = "rememberCredentials"

    public struct Credentials: Codable, Equatable {
        public var username: String?
        public var password: String?
        public var keyPassphrase: String?

        public init(username: String? = nil, password: String? = nil, keyPassphrase: String? = nil) {
            self.username = username
            self.password = password
            self.keyPassphrase = keyPassphrase
        }

        public var isEmpty: Bool {
            (username ?? "").isEmpty && (password ?? "").isEmpty && (keyPassphrase ?? "").isEmpty
        }
    }

    public struct Payload: Codable, Equatable {
        public var profileText: String
        public var credentials: Credentials

        public init(profileText: String, credentials: Credentials) {
            self.profileText = profileText
            self.credentials = credentials
        }
    }

    // MARK: - App side

    /// Options for NETunnelProviderSession.startTunnel(options:).
    public static func startOptions(profileText: String, credentials: Credentials, remember: Bool) -> [String: NSObject] {
        var options: [String: NSObject] = [
            profileTextKey: profileText as NSString,
            rememberCredentialsKey: NSNumber(value: remember),
        ]
        if let username = credentials.username { options[usernameKey] = username as NSString }
        if let password = credentials.password { options[passwordKey] = password as NSString }
        if let passphrase = credentials.keyPassphrase { options[keyPassphraseKey] = passphrase as NSString }
        return options
    }

    // MARK: - Provider side

    /// The secrets for a start: from its options (a start the app requested),
    /// which are also stored for later starts, else the stored ones.
    public static func payload(forStartOptions options: [String: NSObject]?) -> Payload? {
        if let options, let profileText = options[profileTextKey] as? String {
            let credentials = Credentials(
                username: options[usernameKey] as? String,
                password: options[passwordKey] as? String,
                keyPassphrase: options[keyPassphraseKey] as? String
            )
            let remember = (options[rememberCredentialsKey] as? NSNumber)?.boolValue ?? true
            store(Payload(
                profileText: profileText,
                credentials: remember ? credentials : Credentials(username: credentials.username)
            ))
            return Payload(profileText: profileText, credentials: credentials)
        }
        return storedPayload()
    }

    /// Removes the stored password and key passphrase (e.g. after the server
    /// rejected the password), keeping the profile and username.
    public static func forgetStoredCredentials() {
        guard var payload = storedPayload() else { return }
        payload.credentials = Credentials(username: payload.credentials.username)
        store(payload)
    }

    static var storeURL: URL? {
        SharedConfig.containerURL?.appendingPathComponent("tunnel-secrets.json")
    }

    static func store(_ payload: Payload) {
        guard let url = storeURL, let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Owner-only before the secrets go in; a non-atomic write keeps the
        // permissions (an atomic one would create a new file first).
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? data.write(to: url)
    }

    static func storedPayload() -> Payload? {
        guard let url = storeURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}

/// Saved per-profile credentials (app side only), in the app's keychain.
public enum CredentialStore {
    static let service = "com.semivpn.credentials"

    private static func baseQuery(profile: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public static func load(profile: String) -> TunnelSecrets.Credentials? {
        var query = baseQuery(profile: profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TunnelSecrets.Credentials.self, from: data)
    }

    @discardableResult
    public static func save(_ credentials: TunnelSecrets.Credentials, profile: String) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        var query = baseQuery(profile: profile)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Drops the saved password (e.g. after the server rejected it) but
    /// keeps the username for the next prompt.
    public static func forgetPassword(profile: String) {
        guard let saved = load(profile: profile) else { return }
        save(TunnelSecrets.Credentials(username: saved.username, keyPassphrase: saved.keyPassphrase), profile: profile)
    }

    public static func delete(profile: String) {
        SecItemDelete(baseQuery(profile: profile) as CFDictionary)
    }
}
