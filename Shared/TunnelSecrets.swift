import Foundation
import Security

/// Hands the profile and its credentials from the app to the tunnel
/// provider.
///
/// Preferred path: a keychain item in an access group shared by the app and
/// the extension (`keychain-access-groups`), so private keys and passwords
/// never land in the Network Extension preferences, which are stored
/// unencrypted on disk. When the shared group is unavailable (e.g. an
/// unsigned development build), the values travel in the provider
/// configuration as before.
public enum TunnelSecrets {
    /// Provider-configuration keys.
    public static let usernameKey = "username"
    public static let passwordKey = "password"
    public static let keyPassphraseKey = "keyPassphrase"
    /// Set when the profile and credentials are in the shared keychain.
    public static let storedInKeychainKey = "secretsInKeychain"

    static let service = "com.semivpn.tunnel"
    static let account = "active-tunnel"
    static let accessGroupSuffix = "com.semivpn.shared"

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

    struct Payload: Codable {
        var profileText: String
        var credentials: Credentials
    }

    // MARK: - Provider side

    public static func profileText(from configuration: [String: Any]) -> String? {
        if configuration[storedInKeychainKey] as? Bool == true, let payload = loadShared() {
            return payload.profileText
        }
        return configuration[SharedConfig.profileKey] as? String
    }

    public static func credentials(from configuration: [String: Any]) -> Credentials {
        if configuration[storedInKeychainKey] as? Bool == true, let payload = loadShared() {
            return payload.credentials
        }
        return Credentials(
            username: configuration[usernameKey] as? String,
            password: configuration[passwordKey] as? String,
            keyPassphrase: configuration[keyPassphraseKey] as? String
        )
    }

    // MARK: - App side

    /// Builds the secret part of a provider configuration: a keychain
    /// marker when the shared item could be written, the values otherwise.
    public static func providerConfigurationEntries(profileText: String, credentials: Credentials) -> [String: Any] {
        if storeShared(Payload(profileText: profileText, credentials: credentials)) {
            return [storedInKeychainKey: true]
        }
        var entries: [String: Any] = [SharedConfig.profileKey: profileText]
        if let username = credentials.username { entries[usernameKey] = username }
        if let password = credentials.password { entries[passwordKey] = password }
        if let passphrase = credentials.keyPassphrase { entries[keyPassphraseKey] = passphrase }
        return entries
    }

    /// Removes the password and key passphrase from the shared item (when
    /// the user did not ask to remember them), keeping the profile.
    public static func forgetSharedCredentials(keepUsername: Bool = true) {
        guard var payload = loadShared() else { return }
        payload.credentials = Credentials(username: keepUsername ? payload.credentials.username : nil)
        _ = storeShared(payload)
    }

    /// True when the app and extension share a keychain access group.
    public static var sharedKeychainAvailable: Bool { sharedAccessGroup != nil }

    // MARK: - Keychain

    /// The `…com.semivpn.shared` group from this process's
    /// `keychain-access-groups` entitlement (it carries the team prefix).
    static let sharedAccessGroup: String? = {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
              let groups = value as? [String] else { return nil }
        return groups.first { $0.hasSuffix(accessGroupSuffix) }
    }()

    private static func baseQuery(group: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func storeShared(_ payload: Payload) -> Bool {
        guard let group = sharedAccessGroup, let data = try? JSONEncoder().encode(payload) else { return false }
        var query = baseQuery(group: group)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        // The provider can be started at boot (on-demand) before a login.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func loadShared() -> Payload? {
        guard let group = sharedAccessGroup else { return nil }
        var query = baseQuery(group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
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
