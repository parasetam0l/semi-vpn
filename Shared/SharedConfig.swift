import Foundation

/// Shared configuration between the app and the tunnel extension.
///
/// The app stores profiles and the selection in its own Application Support
/// directory (the app group container triggers the system's "access data
/// from other apps" prompt). The extensions receive their configuration at
/// start time through the provider configuration, which the system passes
/// to `startTunnel` — no shared filesystem access is involved.
public enum SharedConfig {
    public static let profilesDirectory = "profiles"
    public static let selectionFile = "selection.json"
    public static let domainsFile = "domains.json"
    public static let localProxyPort: UInt16 = 49280
    public static let localControlPort: UInt16 = 49281
    public static let domainConfigurationDidChangeNotification = Notification.Name(
        "com.semivpn.app.domainConfigurationDidChange"
    )
    public static let selectionDidChangeNotification = Notification.Name(
        "com.semivpn.app.selectionDidChange"
    )

    /// Keys of the provider configuration dictionary.
    public static let profileKey = "profileText"
    public static let selectionKey = "selection"
    public static let fullTunnelKey = "fullTunnel"
    public static let domainRoutingKey = "domainRouting"
    public static let routingModeKey = "routingMode"
    /// Tells the packet provider that macOS is applying native source-app
    /// routing. In that mode the provider may install a default route because
    /// the system scopes it to the configured app rules.
    public static let nativePerAppKey = "nativePerApp"

    /// The app resolves this to `~/Library/Application Support/semi-vpn`;
    /// the (sandboxed) extensions resolve it inside their own containers.
    /// Never the app group.
    public static var containerURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("semi-vpn", isDirectory: true)
    }

    public static var profilesURL: URL? {
        containerURL?.appendingPathComponent(profilesDirectory, isDirectory: true)
    }

    public static var selectionURL: URL? {
        containerURL?.appendingPathComponent(selectionFile)
    }

    public static var domainsURL: URL? {
        containerURL?.appendingPathComponent(domainsFile)
    }

    public static let runtimeStateFile = "runtime_state.json"
    public static var runtimeStateURL: URL? {
        containerURL?.appendingPathComponent(runtimeStateFile)
    }

    public struct RuntimeState: Codable {
        public var vpnStatus: String
        public var forwardingAllowed: Bool
        public var hasVPNIPv6: Bool

        public init(vpnStatus: String = "disconnected", forwardingAllowed: Bool = false, hasVPNIPv6: Bool = false) {
            self.vpnStatus = vpnStatus
            self.forwardingAllowed = forwardingAllowed
            self.hasVPNIPv6 = hasVPNIPv6
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            vpnStatus = try container.decodeIfPresent(String.self, forKey: .vpnStatus) ?? "disconnected"
            forwardingAllowed = try container.decodeIfPresent(Bool.self, forKey: .forwardingAllowed) ?? false
            hasVPNIPv6 = try container.decodeIfPresent(Bool.self, forKey: .hasVPNIPv6) ?? false
        }
    }

    public static func saveRuntimeState(_ state: RuntimeState) {
        ensureDirectories()
        guard let url = runtimeStateURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func loadRuntimeState() -> RuntimeState {
        guard let url = runtimeStateURL, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(RuntimeState.self, from: data) else {
            return RuntimeState()
        }
        return state
    }

    public static func ensureDirectories() {
        guard let profilesURL else { return }
        try? FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)
    }

    public enum RoutingMode: String, Codable, CaseIterable, Identifiable {
        case allApps = "all-apps"
        case selectedAppsOnly = "selected-apps-only"
        case selectedAppsAndBrowser = "selected-apps-and-browser"
        case browserOnly = "browser-only"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .allApps: return "All apps"
            case .selectedAppsOnly: return "Selected apps only"
            case .selectedAppsAndBrowser: return "Selected apps + browser"
            case .browserOnly: return "Browser only"
            }
        }

        public var detail: String {
            switch self {
            case .allApps:
                return "Every application uses the VPN while connected."
            case .selectedAppsOnly:
                return "Only the applications you select use the VPN."
            case .selectedAppsAndBrowser:
                return "Selected applications and listed Chrome domains use the VPN."
            case .browserOnly:
                return "Only listed Chrome domains use the VPN; other apps stay direct."
            }
        }

        public var icon: String {
            switch self {
            case .allApps: return "globe.americas.fill"
            case .selectedAppsOnly: return "app.badge.checkmark.fill"
            case .selectedAppsAndBrowser: return "app.badge.checkmark"
            case .browserOnly: return "globe.badge.chevron.backward"
            }
        }

        public var usesFullTunnel: Bool { self == .allApps }
        public var includesBrowser: Bool {
            self == .selectedAppsAndBrowser || self == .browserOnly
        }
        public var requiresSelectedApps: Bool {
            self == .selectedAppsOnly || self == .selectedAppsAndBrowser
        }
    }

    /// The tunnel configuration selected by the app.
    public struct Selection: Codable, Equatable {
        public var profileFileName: String
        /// Bundle/signing identifiers of the apps routed through the tunnel.
        /// Empty means all apps in All apps mode, or only the SemiVPN browser
        /// proxy helper in Browser only mode.
        public var appIdentifiers: [String]
        /// The single user-facing routing choice. The legacy booleans remain
        /// encoded so older provider configurations and saved selections can
        /// still be read during migration.
        public var routingMode: RoutingMode
        public var fullTunnel: Bool
        /// Enables the local Chrome domain proxy independently of the app
        /// routing policy. In selected-app mode, VPNManager adds the
        /// SemiVPN host app as a helper rule so Chrome itself does not need
        /// to be selected.
        public var domainRouting: Bool
        /// Display entries for the apps added via the picker, so the list
        /// survives app relaunches.
        public var appEntries: [AppEntry]
        /// Tracks whether the enabled-app list has been migrated from the
        /// pre-four-mode selection format.
        public var appSelectionVersion: Int

        public init(profileFileName: String, appIdentifiers: [String], fullTunnel: Bool,
                    appEntries: [AppEntry] = [], domainRouting: Bool = false) {
            self.profileFileName = profileFileName
            self.appIdentifiers = appIdentifiers
            self.routingMode = Self.inferRoutingMode(
                fullTunnel: fullTunnel,
                domainRouting: domainRouting,
                appIdentifiers: appIdentifiers
            )
            self.fullTunnel = routingMode.usesFullTunnel
            self.appEntries = appEntries
            self.domainRouting = routingMode.includesBrowser
            self.appSelectionVersion = 1
        }

        public init(profileFileName: String, appIdentifiers: [String], routingMode: RoutingMode,
                    appEntries: [AppEntry] = []) {
            self.profileFileName = profileFileName
            self.appIdentifiers = appIdentifiers
            self.routingMode = routingMode
            self.fullTunnel = routingMode.usesFullTunnel
            self.appEntries = appEntries
            self.domainRouting = routingMode.includesBrowser
            self.appSelectionVersion = 1
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profileFileName = try container.decode(String.self, forKey: .profileFileName)
            appIdentifiers = try container.decodeIfPresent([String].self, forKey: .appIdentifiers) ?? []
            appEntries = try container.decodeIfPresent([AppEntry].self, forKey: .appEntries) ?? []
            appSelectionVersion = try container.decodeIfPresent(Int.self, forKey: .appSelectionVersion) ?? 0
            let legacyFullTunnel = try container.decodeIfPresent(Bool.self, forKey: .fullTunnel) ?? true
            let legacyDomainRouting = try container.decodeIfPresent(Bool.self, forKey: .domainRouting) ?? false
            let savedMode = try container.decodeIfPresent(RoutingMode.self, forKey: .routingMode)
            routingMode = savedMode ?? Self.inferRoutingMode(
                fullTunnel: legacyFullTunnel,
                domainRouting: legacyDomainRouting,
                appIdentifiers: appIdentifiers
            )
            fullTunnel = routingMode.usesFullTunnel
            domainRouting = routingMode.includesBrowser
        }

        public var profileName: String {
            get { profileFileName }
            set { profileFileName = newValue }
        }
        public var apps: [String] {
            get { appIdentifiers }
            set { appIdentifiers = newValue }
        }

        public static func fromProviderConfiguration(_ config: [String: Any]) -> Selection? {
            guard let identifiers = config[SharedConfig.selectionKey] as? [String] else {
                return nil
            }
            if let rawMode = config[SharedConfig.routingModeKey] as? String,
               let mode = RoutingMode(rawValue: rawMode) {
                return Selection(profileFileName: "", appIdentifiers: identifiers, routingMode: mode)
            }
            return Selection(profileFileName: "", appIdentifiers: identifiers,
                             fullTunnel: config[SharedConfig.fullTunnelKey] as? Bool ?? true,
                             domainRouting: config[SharedConfig.domainRoutingKey] as? Bool ?? false)
        }

        private static func inferRoutingMode(fullTunnel: Bool, domainRouting: Bool,
                                             appIdentifiers: [String]) -> RoutingMode {
            if fullTunnel { return .allApps }
            if domainRouting {
                return appIdentifiers.isEmpty ? .browserOnly : .selectedAppsAndBrowser
            }
            return .selectedAppsOnly
        }
    }

    public static func saveSelection(_ selection: Selection) {
        ensureDirectories()
        guard let url = selectionURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(selection) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func loadSelection() -> Selection? {
        guard let url = selectionURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Selection.self, from: data)
    }

    // MARK: - Domain routing

    public struct DomainConfiguration: Codable, Equatable {
        public var domains: [String]
        /// Domains whose rule also covers every subdomain. Rules not in this
        /// list cover only the exact hostname and its www variant.
        /// A missing field is treated as all domains for compatibility with
        /// configurations written before exact-host rules were supported.
        public var subdomainDomains: [String]
        /// Domains that remain in the user's list but are temporarily bypassed.
        /// A missing field is treated as an empty set for compatibility with
        /// configurations written by earlier builds.
        public var inactiveDomains: [String]
        public var revision: Int
        public var updatedAt: Date

        public init(domains: [String] = [], inactiveDomains: [String] = [], subdomainDomains: [String]? = nil, revision: Int = 0, updatedAt: Date = .distantPast) {
            self.domains = domains
            self.subdomainDomains = (subdomainDomains ?? domains).filter { domains.contains($0) }
            self.inactiveDomains = inactiveDomains.filter { domains.contains($0) }
            self.revision = revision
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case domains
            case subdomainDomains
            case inactiveDomains
            case revision
            case updatedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
            self.domains = domains
            let subdomainDomains = try container.decodeIfPresent([String].self, forKey: .subdomainDomains) ?? domains
            self.subdomainDomains = subdomainDomains.filter { domains.contains($0) }
            let inactiveDomains = try container.decodeIfPresent([String].self, forKey: .inactiveDomains) ?? []
            self.inactiveDomains = inactiveDomains.filter { domains.contains($0) }
            self.revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
            self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        }

        public var activeDomains: [String] {
            domains.filter { !inactiveDomains.contains($0) }
        }

        public var activeSubdomainDomains: [String] {
            subdomainDomains.filter { !inactiveDomains.contains($0) }
        }
    }

    public enum DomainError: LocalizedError {
        case invalidDomain
        case domainNotFound

        public var errorDescription: String? {
            switch self {
            case .invalidDomain:
                return "Enter a hostname such as example.com. A pasted URL is reduced to its hostname; ports and wildcards are not accepted."
            case .domainNotFound:
                return "That domain is not in the domain list."
            }
        }
    }

    private static let domainsLock = NSLock()

    public static func loadDomainConfiguration() -> DomainConfiguration {
        domainsLock.lock()
        defer { domainsLock.unlock() }
        return readDomainConfiguration()
    }

    public static func loadDomains() -> [String] {
        loadDomainConfiguration().domains
    }

    public static func loadActiveDomains() -> [String] {
        loadDomainConfiguration().activeDomains
    }

    public static func loadSubdomainDomains() -> [String] {
        loadDomainConfiguration().subdomainDomains
    }

    public static func loadActiveSubdomainDomains() -> [String] {
        loadDomainConfiguration().activeSubdomainDomains
    }

    @discardableResult
    public static func addDomain(_ rawValue: String, includeSubdomains: Bool = true) throws -> DomainConfiguration {
        guard let domain = routingDomain(rawValue) else { throw DomainError.invalidDomain }
        domainsLock.lock()
        defer { domainsLock.unlock() }

        var configuration = readDomainConfiguration()
        let hasDomain = configuration.domains.contains(domain)
        let needsSubdomainUpdate = hasDomain && includeSubdomains && !configuration.subdomainDomains.contains(domain)
        if !hasDomain || needsSubdomainUpdate {
            if !hasDomain {
                configuration.domains.append(domain)
                configuration.domains.sort()
                configuration.inactiveDomains.removeAll { $0 == domain }
            }
            if includeSubdomains && !configuration.subdomainDomains.contains(domain) {
                configuration.subdomainDomains.append(domain)
                configuration.subdomainDomains.sort()
            }
            configuration.revision += 1
            configuration.updatedAt = Date()
            writeDomainConfiguration(configuration)
        }
        return configuration
    }

    @discardableResult
    public static func removeDomain(_ rawValue: String) throws -> DomainConfiguration {
        guard let normalized = normalizeDomain(rawValue) else { throw DomainError.invalidDomain }
        domainsLock.lock()
        defer { domainsLock.unlock() }

        var configuration = readDomainConfiguration()
        let domain = configuration.domains.contains(normalized)
            ? normalized
            : (routingDomain(normalized) ?? normalized)
        let hadDomain = configuration.domains.contains(domain)
        configuration.domains.removeAll(where: { $0 == domain })
        configuration.subdomainDomains.removeAll(where: { $0 == domain })
        configuration.inactiveDomains.removeAll(where: { $0 == domain })
        if hadDomain {
            configuration.revision += 1
            configuration.updatedAt = Date()
            writeDomainConfiguration(configuration)
        }
        return configuration
    }

    @discardableResult
    public static func setDomainEnabled(_ rawValue: String, enabled: Bool) throws -> DomainConfiguration {
        guard let normalized = normalizeDomain(rawValue) else { throw DomainError.invalidDomain }
        domainsLock.lock()
        defer { domainsLock.unlock() }

        var configuration = readDomainConfiguration()
        let domain = configuration.domains.contains(normalized)
            ? normalized
            : (routingDomain(normalized) ?? normalized)
        guard configuration.domains.contains(domain) else { throw DomainError.domainNotFound }

        let wasEnabled = !configuration.inactiveDomains.contains(domain)
        guard wasEnabled != enabled else { return configuration }

        if enabled {
            configuration.inactiveDomains.removeAll { $0 == domain }
        } else if !configuration.inactiveDomains.contains(domain) {
            configuration.inactiveDomains.append(domain)
            configuration.inactiveDomains.sort()
        }
        configuration.revision += 1
        configuration.updatedAt = Date()
        writeDomainConfiguration(configuration)
        return configuration
    }

    /// Canonicalizes a user-entered hostname for storage and matching.
    /// `https://example.com/path` and `example.com` intentionally do not
    /// become different routing entries; only hostnames are stored.
    public static func normalizeDomain(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.contains("://") {
            guard let host = URL(string: value)?.host else { return nil }
            value = host
        } else if let host = URL(string: "http://" + value)?.host {
            value = host
        } else {
            value = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !value.isEmpty, !value.contains(":"), !value.hasPrefix("*.") else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 &&
            label.first != "-" && label.last != "-" &&
            label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return nil }
        return value
    }

    /// Uses the registrable-looking hostname without a leading `www.` as the
    /// rule key. Exact-host rules still match both this key and its www form.
    /// This deliberately does not attempt public-suffix parsing; users may
    /// add a deeper hostname when that is the scope they intend.
    public static func routingDomain(_ rawValue: String) -> String? {
        guard let domain = normalizeDomain(rawValue) else { return nil }
        if domain.hasPrefix("www.") {
            return String(domain.dropFirst(4))
        }
        return domain
    }

    /// Returns true for exact domains, their www variants, and optionally all
    /// subdomains, while keeping lookalikes such as `notexample.com` out.
    public static func domainMatches(host rawHost: String, domains: [String] = loadDomains(), subdomainDomains: [String]? = nil) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !host.isEmpty else { return false }
        let wildcardDomains = Set(subdomainDomains ?? domains)
        return domains.contains { domain in
            host == domain || host == "www." + domain ||
                (wildcardDomains.contains(domain) && host.hasSuffix("." + domain))
        }
    }

    private static func readDomainConfiguration() -> DomainConfiguration {
        guard let url = domainsURL, let data = try? Data(contentsOf: url) else {
            return DomainConfiguration()
        }
        if let configuration = try? JSONDecoder().decode(DomainConfiguration.self, from: data) {
            return configuration
        }
        // Be tolerant of an early development build that wrote a plain array.
        if let domains = try? JSONDecoder().decode([String].self, from: data) {
            return DomainConfiguration(domains: domains.compactMap(normalizeDomain), revision: 1, updatedAt: Date())
        }
        return DomainConfiguration()
    }

    private static func writeDomainConfiguration(_ configuration: DomainConfiguration) {
        ensureDirectories()
        guard let url = domainsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configuration) else { return }
        try? data.write(to: url, options: .atomic)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: domainConfigurationDidChangeNotification,
                object: nil
            )
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.semivpn.app.domainConfigurationDidChange"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    public static func saveProfile(_ text: String, name: String) -> Bool {
        // Profiles contain private keys and credentials: the keychain is
        // the primary store. Files are only a fallback for unsigned
        // development builds where the keychain is unavailable, and legacy
        // file profiles migrate into the keychain on first read.
        if ProfileKeychain.save(text, account: name) {
            ProfileKeychain.removeLegacyFile(name: name)
            return true
        }
        return saveProfileFile(text, name: name)
    }

    public static func loadProfile(name: String) -> String? {
        if let text = ProfileKeychain.load(account: name) {
            return text
        }
        // Legacy file profile: migrate into the keychain.
        guard let url = profilesURL?.appendingPathComponent(name),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        if ProfileKeychain.save(text, account: name) {
            ProfileKeychain.removeLegacyFile(name: name)
        }
        return text
    }

    public static func profileNames() -> [String] {
        var names = Set(ProfileKeychain.accounts())
        if let url = profilesURL,
           let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            names.formUnion(files.filter { $0.hasSuffix(".ovpn") })
        }
        return names.sorted()
    }

    public static func deleteProfile(name: String) {
        ProfileKeychain.delete(account: name)
        ProfileKeychain.removeLegacyFile(name: name)
    }

    private static func saveProfileFile(_ text: String, name: String) -> Bool {
        ensureDirectories()
        guard let url = profilesURL?.appendingPathComponent(name) else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}

/// Generic-password keychain storage for profile blobs. Only the app
/// reads/writes profiles; the extensions receive the selected profile text
/// through the provider configuration at tunnel start.
enum ProfileKeychain {
    static let service = "com.semivpn.profiles"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func save(_ text: String, account: String) -> Bool {
        let data = Data(text.utf8)
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func accounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    static func removeLegacyFile(name: String) {
        guard let url = SharedConfig.profilesURL?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// An application added to the per-app routing list.
public struct AppEntry: Identifiable, Codable, Hashable {
    public var id: String { bundleIdentifier }
    public var name: String
    public var bundleIdentifier: String
    public var signingIdentifier: String
    public var path: String
    /// The macOS code-signing designated requirement used by NEAppRule.
    /// Optional for backwards compatibility with older selection files.
    public var designatedRequirement: String?

    public init(name: String, bundleIdentifier: String, signingIdentifier: String, path: String,
                designatedRequirement: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentifier = signingIdentifier
        self.path = path
        self.designatedRequirement = designatedRequirement
    }
}
