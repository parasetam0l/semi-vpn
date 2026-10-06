import AppKit
import Combine
import Network
import NetworkExtension
import OpenVPNCore
import SwiftUI
import UniformTypeIdentifiers

/// The state behind the window, the menu bar panel and Settings: profiles,
/// the routing choice, the apps and websites that use the VPN, and the
/// actions on them. There is one instance, so all three always agree.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel(vpn: VPNManager())

    let vpn: VPNManager

    @Published private(set) var profiles: [String] = []
    @Published private(set) var selectedProfile: String?
    @Published private(set) var routingMode: SharedConfig.RoutingMode = .allApps
    /// Apps added with the picker, by bundle identifier.
    @Published private(set) var addedApps: [String: AppEntry] = [:]
    /// The added apps that are switched on.
    @Published private(set) var selectedApps: Set<String> = []
    @Published private(set) var domains: [String] = []
    @Published private(set) var subdomainDomains: Set<String> = []
    @Published private(set) var inactiveDomains: Set<String> = []
    @Published private(set) var blockWhenDisconnected = false
    @Published private(set) var connecting = false
    @Published private(set) var routingRepairPhase: RoutingRepairPhase = .idle
    /// The list the window shows when the mode uses both: apps first.
    @Published var listKind: ListKind = .apps
    /// What the window's list is filtered by.
    @Published var listSearch = ""
    @Published private(set) var diagnostics = Diagnostics()

    /// Presented by the window.
    @Published var connectError: String?
    @Published var credentialEditor: VPNManager.CredentialRequest?

    enum ListKind: Hashable {
        case apps, websites
    }

    struct Diagnostics: Equatable {
        var tunnelRegistered = false
        var vpnConfigSaved = false
        var perAppConfigSaved = false
    }

    struct ProfileMeta: Equatable {
        var displayName: String
        var host: String
        var protocolName: String
    }

    private var cancellables: Set<AnyCancellable> = []
    /// Connect at startup, waiting for the network; Connect and Disconnect
    /// cancel it.
    private var launchConnectTask: Task<Void, Never>?
    private let isPreview: Bool
    private var previewMeta: [String: ProfileMeta] = [:]
    private var previewIcons: [String: NSImage] = [:]

    init(vpn: VPNManager) {
        self.vpn = vpn
        isPreview = false
        vpn.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        vpn.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.connectError = message }
            .store(in: &cancellables)
        vpn.stoppedForExtensionUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.restartAfterExtensionUpdate() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: SharedConfig.domainConfigurationDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDomains() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: SharedConfig.selectionDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        ExtensionMonitor.shared.$browserRoutingBroken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] broken in
                guard let self, !broken, !self.routingRepairPhase.isBusy else { return }
                self.routingRepairPhase = .idle
            }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: - Status

    /// Connect starts before Network Extension reports `.connecting`; show
    /// that state right away instead of a stale "Not connected".
    var displayedStatus: NEVPNStatus {
        if (connecting || vpn.isReconnecting) && (vpn.status == .disconnected || vpn.status == .invalid) {
            return .connecting
        }
        return vpn.status
    }

    var isConnected: Bool { displayedStatus == .connected }

    var isTunnelActive: Bool {
        let status = displayedStatus
        return status == .connected || status == .connecting || status == .reasserting
    }

    /// What differs from the running tunnel: "profile", "route" or "apps".
    /// macOS applies these only when the tunnel starts again (reconnect).
    var pendingChanges: [String] {
        guard isTunnelActive, !vpn.isReconnecting, let applied = vpn.appliedRouting,
              let selectedProfile else { return [] }
        let current = SharedConfig.AppliedRouting(profileName: selectedProfile, routingMode: routingMode,
                                                  appIdentifiers: Array(selectedApps))
        var changes: [String] = []
        if applied.profileName != current.profileName { changes.append("profile") }
        if applied.routingMode != current.routingMode {
            changes.append("route")
        } else if applied.appIdentifiers != current.appIdentifiers, !VPNManager.appliesAppRulesLive {
            // Where macOS applies app rules at once, they are saved into the
            // running configuration within a second; nothing to reconnect.
            changes.append("apps")
        }
        return changes
    }

    /// The profile the running tunnel uses, which differs from the selected
    /// one until a reconnect.
    var connectedProfile: String? {
        isTunnelActive ? vpn.appliedRouting?.profileName : nil
    }

    /// The status orb's and the hero's look.
    var orbState: OrbState {
        switch displayedStatus {
        case .connected: return vpn.isReconnecting ? .changing : .connected
        case .connecting, .reasserting, .disconnecting: return .changing
        default: return .off
        }
    }

    var statusTitle: String {
        if vpn.isReconnecting { return "Reconnecting…" }
        switch displayedStatus {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        case .disconnected, .invalid: return "Not Connected"
        @unknown default: return "Not Connected"
        }
    }

    var statusColor: Color {
        switch displayedStatus {
        case .connected: return SemiTheme.green
        case .connecting, .reasserting, .disconnecting: return SemiTheme.amber
        default: return .secondary
        }
    }

    var connectionStatusText: String {
        switch vpn.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .reasserting: return "Reconnecting"
        case .invalid: return vpn.hasSavedConfiguration ? "Disabled" : "Not configured"
        case .disconnected: return "Disconnected"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Profiles

    func profileMeta(_ name: String) -> ProfileMeta {
        if isPreview {
            return previewMeta[name] ?? ProfileMeta(displayName: name, host: "unknown", protocolName: "OpenVPN")
        }
        let fallback = name.replacingOccurrences(of: ".ovpn", with: "")
        guard let entry = ProfileCatalog.shared.entry(for: name) else {
            return ProfileMeta(displayName: fallback, host: "unknown", protocolName: "OpenVPN")
        }
        let commonName = Self.certificateCommonName(in: entry.text) ?? fallback
        guard let profile = entry.profile, let remote = profile.remotes.first else {
            return ProfileMeta(displayName: commonName, host: "unknown", protocolName: "OpenVPN")
        }
        return ProfileMeta(displayName: commonName, host: remote.host,
                           protocolName: "OpenVPN \(profile.transport(for: remote).rawValue.uppercased())")
    }

    func chooseProfile(_ name: String) {
        guard profiles.contains(name), name != selectedProfile else { return }
        selectedProfile = name
        saveCurrentSelection()
        AppLogger.log("selected profile: \(name)")
    }

    /// The credentials a profile can store, or nil when it needs none.
    func credentialRequest(for name: String) -> VPNManager.CredentialRequest? {
        guard !isPreview, let profile = ProfileCatalog.shared.entry(for: name)?.profile else { return nil }
        let needsUserPass = profile.requiresAuthUserPass && profile.authUserPass?.password == nil
        guard needsUserPass || profile.requiresKeyPassphrase else { return nil }
        return VPNManager.CredentialRequest(
            profileName: name,
            needsUsernamePassword: needsUserPass,
            needsKeyPassphrase: profile.requiresKeyPassphrase,
            username: CredentialStore.load(profile: name)?.username
        )
    }

    func hasSavedCredentials(_ name: String) -> Bool {
        !isPreview && CredentialStore.load(profile: name) != nil
    }

    func showProfilePicker() {
        guard !isPreview else { return }
        AppLogger.log("import button clicked")
        let panel = NSOpenPanel()
        panel.title = "Import an OpenVPN Profile"
        panel.message = "SemiVPN stores a copy of the profile (.ovpn) privately in its app container."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ovpn") ?? .data]
        Self.present(panel) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.importProfile(from: url)
            }
        }
    }

    /// Imports the profiles chosen in the scan sheet.
    func importProfiles(_ urls: [URL]) {
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            importProfile(from: url, askName: false)
        }
        profiles = SharedConfig.profileNames()
    }

    func importProfile(from url: URL, askName: Bool = true) {
        guard !isPreview else { return }
        AppLogger.log("importing profile: \(url.lastPathComponent)")
        let text: String
        let parsed: OVPNProfile
        var embeddedFiles: [String] = []
        do {
            // Embed referenced files (ca ca.crt, tls-auth ta.key 1, ...) so
            // the stored profile is self-contained.
            let original = try String(contentsOf: url, encoding: .utf8)
            let inlined = try OVPNProfileInliner.inlineReportingFiles(original, baseDirectory: url.deletingLastPathComponent())
            text = inlined.text
            embeddedFiles = inlined.files
            parsed = try OVPNParser().parse(text)
        } catch {
            Self.showImportError("This file isn’t a valid OpenVPN profile: \(error.localizedDescription)")
            return
        }
        if !parsed.fatalIssues.isEmpty {
            Self.showImportError("\(url.lastPathComponent) can’t be used:\n" +
                parsed.fatalIssues.map { "• \($0.message)" }.joined(separator: "\n"))
            return
        }
        let warnings = parsed.issues.filter { $0.severity == .warning }.map(\.message)

        var name = Self.certificateCommonName(in: text) ?? url.deletingPathExtension().lastPathComponent
        // Profiles that pulled in other files always ask, even from a scan.
        if askName || !embeddedFiles.isEmpty {
            let host = parsed.remotes.first?.host ?? "unknown"
            let protocolName = "OpenVPN \(parsed.transport.rawValue.uppercased())"
            let alert = NSAlert()
            alert.messageText = "Add this profile?"
            let embeddedNote = embeddedFiles.isEmpty ? [] : ["Embeds: " + embeddedFiles.joined(separator: ", ")]
            alert.informativeText = ([url.lastPathComponent] + embeddedNote + warnings.map { "⚠︎ \($0)" })
                .joined(separator: "\n")
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            let detailLabel = NSTextField(labelWithString: "\(host)  ·  \(protocolName)")
            detailLabel.font = NSFont.systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            stack.addArrangedSubview(nameLabel)
            stack.addArrangedSubview(detailLabel)
            alert.accessoryView = stack
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if name.isEmpty { name = "profile" }
        if SharedConfig.profileNames().contains(name + ".ovpn") {
            name += "-\(Int(Date().timeIntervalSince1970))"
        }
        if SharedConfig.saveProfile(text, name: name + ".ovpn") {
            ProfileCatalog.shared.invalidate()
            profiles = SharedConfig.profileNames()
            selectedProfile = name + ".ovpn"
            saveCurrentSelection()
        } else {
            Self.showImportError("The profile couldn’t be stored.")
        }
    }

    private static func showImportError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SemiVPN Couldn’t Import the Profile"
        alert.informativeText = message
        alert.runModal()
    }

    func deleteProfile(_ name: String) {
        guard !isPreview else { return }
        let meta = profileMeta(name)
        let alert = NSAlert()
        alert.messageText = "Delete “\(meta.displayName)”?"
        alert.informativeText = "The profile for \(meta.host) is removed from SemiVPN. This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SharedConfig.deleteProfile(name: name)
        ProfileCatalog.shared.invalidate()
        profiles = SharedConfig.profileNames()
        if selectedProfile == name {
            selectedProfile = profiles.first
            if selectedProfile != nil { saveCurrentSelection() }
        }
        AppLogger.log("deleted profile \(name)")
    }

    func saveCredentials(_ credentials: TunnelSecrets.Credentials, for request: VPNManager.CredentialRequest) {
        CredentialStore.save(credentials, profile: request.profileName)
        credentialEditor = nil
    }

    func forgetCredentials(for request: VPNManager.CredentialRequest) {
        CredentialStore.delete(profile: request.profileName)
        credentialEditor = nil
    }

    /// The client certificate's subject common name, the profile's identity.
    /// Uses the first certificate of the <cert> block (later ones are its
    /// chain).
    nonisolated static func certificateCommonName(in text: String) -> String? {
        guard let start = text.range(of: "<cert>"),
              let end = text.range(of: "</cert>", range: start.upperBound..<text.endIndex) else { return nil }
        let block = text[start.upperBound..<end.lowerBound]
        // Some profiles embed an `openssl x509` text dump before the PEM.
        guard let begin = block.range(of: "-----BEGIN CERTIFICATE-----"),
              let finish = block.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<block.endIndex) else { return nil }
        let base64 = block[begin.upperBound..<finish.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess,
              let name = commonName as String?,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }

    // MARK: - Routing

    func setRoutingMode(_ mode: SharedConfig.RoutingMode) {
        guard mode != routingMode else { return }
        routingMode = mode
        saveCurrentSelection()
    }

    var sortedApps: [AppEntry] {
        addedApps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isAppEnabled(_ app: AppEntry) -> Bool {
        selectedApps.contains(app.bundleIdentifier) || selectedApps.contains(app.signingIdentifier)
    }

    func setApp(_ app: AppEntry, enabled: Bool) {
        if enabled {
            selectedApps.insert(app.bundleIdentifier)
        } else {
            selectedApps.remove(app.bundleIdentifier)
            selectedApps.remove(app.signingIdentifier)
        }
        saveCurrentSelection()
    }

    /// The lists the current mode uses: apps, websites, or both.
    var listKinds: [ListKind] {
        var kinds: [ListKind] = []
        if routingMode.requiresSelectedApps { kinds.append(.apps) }
        if routingMode.includesBrowser { kinds.append(.websites) }
        return kinds
    }

    /// The list on screen: the chosen one when the mode uses it.
    var shownListKind: ListKind? {
        listKinds.contains(listKind) ? listKind : listKinds.first
    }

    var enabledAppCount: Int { addedApps.values.filter(isAppEnabled).count }
    var enabledDomainCount: Int { domains.count - inactiveDomains.intersection(domains).count }

    func setApps(_ identifiers: Set<String>, enabled: Bool) {
        for identifier in identifiers {
            guard let app = addedApps[identifier] else { continue }
            if enabled {
                selectedApps.insert(app.bundleIdentifier)
            } else {
                selectedApps.remove(app.bundleIdentifier)
                selectedApps.remove(app.signingIdentifier)
            }
        }
        saveCurrentSelection()
    }

    func removeApps(_ identifiers: Set<String>) {
        for identifier in identifiers {
            guard let app = addedApps.removeValue(forKey: identifier) else { continue }
            selectedApps.remove(app.bundleIdentifier)
            selectedApps.remove(app.signingIdentifier)
        }
        saveCurrentSelection()
        AppLogger.log("removed \(identifiers.count) app(s)")
    }

    /// Asks before removing apps or websites; `identifiers` are bundle
    /// identifiers or domains.
    func confirmRemoval(_ kind: ListKind, _ identifiers: Set<String>, then remove: @escaping () -> Void) {
        guard !identifiers.isEmpty else { return }
        let names = identifiers
            .map { kind == .apps ? (addedApps[$0]?.name ?? $0) : $0 }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let noun = kind == .apps ? (names.count == 1 ? "app" : "apps") : (names.count == 1 ? "website" : "websites")
        let alert = NSAlert()
        if names.count == 1 {
            alert.messageText = "Remove “\(names[0])”?"
            alert.informativeText = "It stops using the VPN. You can add it again later."
        } else {
            alert.messageText = "Remove \(names.count) \(noun)?"
            let shown = names.prefix(5).joined(separator: ", ")
            alert.informativeText = shown + (names.count > 5 ? " and \(names.count - 5) more" : "")
                + " stop using the VPN. You can add them again later."
        }
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        Self.run(alert) { confirmed in
            if confirmed { remove() }
        }
    }

    func appIcon(_ app: AppEntry) -> NSImage {
        previewIcons[app.bundleIdentifier] ?? NSWorkspace.shared.icon(forFile: app.path)
    }

    func showAppPicker() {
        guard !isPreview else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Apps"
        panel.message = "Choose the apps that use the VPN. SemiVPN only considers the apps you add here."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        Self.present(panel) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                guard let entry = Self.appEntry(at: url) else { continue }
                self.addedApps[entry.bundleIdentifier] = entry
                self.selectedApps.insert(entry.bundleIdentifier)
            }
            self.saveCurrentSelection()
        }
    }

    // MARK: - Websites

    func isDomainEnabled(_ domain: String) -> Bool { !inactiveDomains.contains(domain) }

    /// Adds a website; returns an error message to show, or nil.
    func addDomain(_ input: String, includeSubdomains: Bool) -> String? {
        guard let domain = SharedConfig.routingDomain(input) else {
            return SharedConfig.DomainError.invalidDomain.localizedDescription
        }
        if domains.contains(domain) || domains.contains("www." + domain) {
            return "\(domain) is already in the list."
        }
        guard !isPreview else { return nil }
        do {
            apply(try SharedConfig.addDomain(domain, includeSubdomains: includeSubdomains))
            AppLogger.log("added domain rule: \(domain) scope=\(includeSubdomains ? "subdomains" : "domain-and-www")")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setDomainEnabled(_ domain: String, enabled: Bool) {
        #if DEBUG
        // The preview window's switches change only what it shows.
        if isPreview {
            if enabled { inactiveDomains.remove(domain) } else { inactiveDomains.insert(domain) }
            return
        }
        #endif
        guard !isPreview else { return }
        do {
            apply(try SharedConfig.setDomainEnabled(domain, enabled: enabled))
            AppLogger.log("domain rule \(enabled ? "enabled" : "paused"): \(domain)")
        } catch {
            AppLogger.log("updating domain rule failed: \(error.localizedDescription)")
        }
    }

    func setDomainsEnabled(_ domains: Set<String>, enabled: Bool) {
        guard !isPreview, !domains.isEmpty else { return }
        apply(SharedConfig.setDomainsEnabled(Array(domains), enabled: enabled))
        AppLogger.log("\(domains.count) domain rule(s) \(enabled ? "enabled" : "paused")")
    }

    func removeDomains(_ domains: Set<String>) {
        guard !isPreview, !domains.isEmpty else { return }
        apply(SharedConfig.removeDomains(Array(domains)))
        AppLogger.log("removed \(domains.count) domain rule(s)")
    }

    func setBlockWhenDisconnected(_ enabled: Bool) {
        guard !isPreview else { return }
        blockWhenDisconnected = SharedConfig.setBlockWhenDisconnected(enabled).blockWhenDisconnected
        AppLogger.log("browser fail-closed \(enabled ? "enabled" : "disabled")")
    }

    private func apply(_ configuration: SharedConfig.DomainConfiguration) {
        domains = configuration.domains
        subdomainDomains = Set(configuration.subdomainDomains)
        inactiveDomains = Set(configuration.inactiveDomains)
        blockWhenDisconnected = configuration.blockWhenDisconnected
    }

    // MARK: - Import and export

    func exportWebsites() {
        let rules = domains.map {
            SharedConfig.DomainRule(domain: $0, includeSubdomains: subdomainDomains.contains($0), enabled: isDomainEnabled($0))
        }
        save(RoutingListFile.text(forWebsites: rules), suggestedName: "SemiVPN Websites.txt", title: "Export Websites")
    }

    func importWebsites() {
        guard !isPreview else { return }
        openListFile(title: "Import Websites") { [weak self] text in
            guard let self else { return }
            let parsed = RoutingListFile.websites(from: text)
            let result = SharedConfig.addDomains(parsed.entries)
            self.apply(result.configuration)
            AppLogger.log("imported \(result.added.count) domain rule(s)")
            Self.showImportSummary(
                added: result.added.count, noun: "website",
                alreadyListed: Set(parsed.entries.map(\.domain)).count - result.added.count,
                problems: parsed.rejected.map { "Line \($0.line): \($0.text)" }
            )
        }
    }

    func exportApps() {
        let lines = sortedApps.map { RoutingListFile.AppLine(identifier: $0.bundleIdentifier, enabled: isAppEnabled($0)) }
        save(RoutingListFile.text(forApps: lines), suggestedName: "SemiVPN Apps.txt", title: "Export Apps")
    }

    func importApps() {
        guard !isPreview else { return }
        openListFile(title: "Import Apps") { [weak self] text in
            guard let self else { return }
            let parsed = RoutingListFile.apps(from: text)
            var problems = parsed.rejected.map { "Line \($0.line): \($0.text)" }
            var added = 0
            var alreadyListed = 0
            for line in parsed.entries {
                let url = line.identifier.hasPrefix("/")
                    ? URL(fileURLWithPath: line.identifier)
                    : NSWorkspace.shared.urlForApplication(withBundleIdentifier: line.identifier)
                guard let url, let entry = Self.appEntry(at: url) else {
                    problems.append("Not installed: \(line.identifier)")
                    continue
                }
                if self.addedApps[entry.bundleIdentifier] != nil {
                    alreadyListed += 1
                    continue
                }
                self.addedApps[entry.bundleIdentifier] = entry
                if line.enabled { self.selectedApps.insert(entry.bundleIdentifier) }
                added += 1
            }
            self.saveCurrentSelection()
            AppLogger.log("imported \(added) app(s)")
            Self.showImportSummary(added: added, noun: "app", alreadyListed: alreadyListed, problems: problems)
        }
    }

    private static func appEntry(at url: URL) -> AppEntry? {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppEntry(
            name: name,
            bundleIdentifier: identifier,
            signingIdentifier: identifier,
            path: url.path,
            designatedRequirement: AppCodeSignature.designatedRequirement(for: url)
        )
    }

    private func save(_ text: String, suggestedName: String, title: String) {
        guard !isPreview else { return }
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.plainText]
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "SemiVPN Couldn’t Save the List"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window = NSApp.keyWindow, !(window is NSPanel) {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    private func openListFile(title: String, read: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "Choose a text file with one entry per line, such as one exported from SemiVPN."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        Self.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                Self.showImportSummary(added: 0, noun: "entry", alreadyListed: 0, problems: ["The file isn’t a UTF-8 text file."])
                return
            }
            read(text)
        }
    }

    private static func showImportSummary(added: Int, noun: String, alreadyListed: Int, problems: [String]) {
        let alert = NSAlert()
        alert.messageText = added == 1 ? "Added 1 \(noun)" : "Added \(added) \(noun)s"
        var details: [String] = []
        if alreadyListed > 0 {
            details.append(alreadyListed == 1 ? "1 was already in the list." : "\(alreadyListed) were already in the list.")
        }
        if !problems.isEmpty {
            details.append("Skipped:\n" + problems.prefix(10).joined(separator: "\n")
                + (problems.count > 10 ? "\n… and \(problems.count - 10) more" : ""))
        }
        alert.informativeText = details.joined(separator: "\n\n")
        if added == 0 && !problems.isEmpty { alert.alertStyle = .warning }
        run(alert) { _ in }
    }

    /// Shows an alert as a sheet on the key window, or as a dialog; calls
    /// back with whether the first button was chosen.
    private static func run(_ alert: NSAlert, completion: @escaping (Bool) -> Void) {
        if let window = NSApp.keyWindow, !(window is NSPanel), window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    // MARK: - Connection

    func connect(credentials: TunnelSecrets.Credentials? = nil, remember: Bool = false) {
        #if DEBUG
        if isPreview { vpn.simulatePreviewConnection(true); return }
        #endif
        guard !isPreview, let selectedProfile, !connecting else { return }
        launchConnectTask?.cancel()
        connectError = nil
        connecting = true
        AppLogger.log("connect requested: profile=\(selectedProfile) mode=\(routingMode.rawValue) apps=\(selectedApps.count)")
        saveCurrentSelection()
        Task {
            do {
                try await vpn.start(credentials: credentials, remember: remember)
                AppLogger.log("connect started")
            } catch VPNManager.StartError.credentialsRequired {
                // The window asks for them (vpn.credentialRequest).
                AppLogger.log("connect: waiting for credentials")
                AppDelegate.shared?.showWindow()
            } catch {
                connectError = "SemiVPN couldn’t connect: \(error.localizedDescription)"
                AppLogger.log("connect failed: \(error)")
                AppDelegate.shared?.showWindow()
            }
            connecting = false
        }
    }

    func disconnect() {
        #if DEBUG
        if isPreview { vpn.simulatePreviewConnection(false); return }
        #endif
        guard !isPreview else { return }
        launchConnectTask?.cancel()
        vpn.stop()
    }

    /// The profile connected last, which Connect at startup uses; the
    /// selected one when that profile is gone or none connected yet.
    var lastConnectedProfile: String? {
        if let name = vpn.appliedRouting?.profileName, profiles.contains(name) { return name }
        return selectedProfile
    }

    /// Connect at startup (Settings → General): connects to the profile
    /// connected last once the Mac is online, which at login can be a few
    /// seconds after SemiVPN opens. Nothing happens when the tunnel already
    /// runs, for example started by per-app on-demand.
    func connectAtLaunch() {
        guard !isPreview else { return }
        launchConnectTask = Task {
            await vpn.waitUntilRestored()
            guard vpn.status == .disconnected || vpn.status == .invalid else {
                AppLogger.log("connect at startup: the tunnel is already \(vpn.status.rawValue)")
                return
            }
            for await path in NWPathMonitor() where path.status == .satisfied { break }
            guard !Task.isCancelled, vpn.status == .disconnected || vpn.status == .invalid,
                  !vpn.isReconnecting, let profile = lastConnectedProfile else { return }
            AppLogger.log("connect at startup: \(profile)")
            chooseProfile(profile)
            connect()
        }
    }

    /// macOS stopped the tunnel to replace the network extension with the
    /// updated build. Per-app on-demand starts it again within seconds; in
    /// All Apps mode, connect again as before the update.
    private func restartAfterExtensionUpdate() {
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard vpn.endExtensionUpdateRestart() else { return }
            AppLogger.log("network extension updated: connecting again")
            connect()
        }
    }

    /// Applies pending changes: stops the tunnel and starts it again with
    /// the current profile, route and apps.
    func reconnect() {
        guard !isPreview, isTunnelActive, !vpn.isReconnecting else { return }
        connectError = nil
        AppLogger.log("reconnect to apply: \(pendingChanges.joined(separator: ", "))")
        Task {
            do {
                try await vpn.reconnect()
            } catch VPNManager.StartError.credentialsRequired {
                AppDelegate.shared?.showWindow()
            } catch {
                connectError = "SemiVPN couldn’t reconnect: \(error.localizedDescription)"
                AppLogger.log("reconnect failed: \(error)")
                AppDelegate.shared?.showWindow()
            }
        }
    }

    // MARK: - Routing repair

    /// Clears macOS's stale per-app rule record and restarts its VPN service
    /// (the user enters an administrator password), reconnects, and waits
    /// for SemiProxy to confirm that it uses the VPN again.
    func repairVPNRouting() {
        guard !isPreview, !routingRepairPhase.isBusy else { return }
        routingRepairPhase = .restartingService
        AppLogger.log("routing repair: restarting the macOS VPN service")
        VPNRoutingRepair.restartVPNService { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(.cancelled):
                self.routingRepairPhase = .idle
            case .failure(.failed(let message)):
                AppLogger.log("routing repair failed: \(message)")
                self.routingRepairPhase = .failed(message)
            case .success:
                self.routingRepairPhase = .reconnecting
                // launchd starts the service again at once; give it a moment
                // to load the VPN configurations.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let reconnectStarted = Date()
                    self.connect()
                    self.routingRepairPhase = .verifying
                    self.verifyRoutingRepair(since: reconnectStarted, remainingChecks: 30)
                }
            }
        }
    }

    private func verifyRoutingRepair(since start: Date, remainingChecks: Int) {
        let monitor = ExtensionMonitor.shared
        if let health = SharedConfig.loadProxyHealth(), health.checkedAt > start,
           SharedConfig.loadRuntimeState().forwardingAllowed {
            AppLogger.log("routing repair: \(health.tunnelBypassed ? "still outside the VPN" : "browser traffic uses the VPN again")")
            routingRepairPhase = health.tunnelBypassed ? .stillBroken : .idle
            monitor.refresh()
            return
        }
        guard remainingChecks > 0 else {
            routingRepairPhase = monitor.browserRoutingBroken ? .stillBroken : .idle
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.verifyRoutingRepair(since: start, remainingChecks: remainingChecks - 1)
        }
    }

    // MARK: - Diagnostics

    func refreshDiagnostics() {
        guard !isPreview else { return }
        Task.detached(priority: .utility) {
            let registered = Self.extensionRegistered(bundleID: SystemExtensionInstaller.identifier)
            await MainActor.run { self.diagnostics.tunnelRegistered = registered }
        }
        Task {
            let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
            let ours = managers.filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == SystemExtensionInstaller.identifier
            }
            diagnostics.vpnConfigSaved = !ours.isEmpty
            diagnostics.perAppConfigSaved = ours.contains {
                $0.routingMethod == .sourceApplication && ($0.copyAppRules()?.isEmpty == false)
            }
        }
    }

    /// Whether the tunnel's system extension is known to the system.
    nonisolated private static func extensionRegistered(bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        // Read before waiting: a full pipe would otherwise block the tool.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").contains { $0.contains(bundleID) && $0.contains("[activated enabled]") }
    }

    func revealLogFile() {
        AppLogger.log("reveal log file")
        guard let url = AppLogger.logURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - Loading and saving

    func refresh() {
        guard !isPreview else { return }
        profiles = SharedConfig.profileNames()
        refreshDomains()
        ChromeExtensionInstaller.syncInstalledExtensionIfNeeded()
        ExtensionMonitor.shared.refresh()
        vpn.loadSelection()
        if let selection = vpn.selection, profiles.contains(selection.profileName) {
            selectedProfile = selection.profileName
            routingMode = selection.routingMode
            addedApps = Dictionary(
                selection.appEntries.map { ($0.bundleIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            selectedApps = Set(selection.appIdentifiers)
            if selection.appSelectionVersion == 0,
               routingMode.requiresSelectedApps,
               selectedApps.isEmpty,
               !addedApps.isEmpty {
                // Older builds cleared appIdentifiers when switching through
                // Browser only or All apps. App picker entries were always
                // auto-enabled, so restore that lost state once.
                selectedApps = Set(addedApps.keys)
                saveCurrentSelection()
                AppLogger.log("migrated enabled app selection from saved app entries")
            }
        } else {
            // No selection, or its profile was deleted.
            selectedProfile = profiles.first
            selectedApps = []
            routingMode = .allApps
            addedApps = [:]
        }
    }

    func refreshDomains() {
        guard !isPreview else { return }
        apply(SharedConfig.loadDomainConfiguration())
    }

    private var appRulesUpdate: Task<Void, Never>?

    /// After app changes while connected, writes the new app rules into the
    /// running configuration once the changes settle. macOS 27 applies them
    /// at once; on earlier versions the Reconnect notice stays until the
    /// tunnel restarts.
    private func scheduleAppRulesUpdate() {
        guard !isPreview, isTunnelActive else { return }
        appRulesUpdate?.cancel()
        appRulesUpdate = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await vpn.saveAppRulesToRunningConfiguration()
        }
    }

    private func saveCurrentSelection() {
        guard !isPreview, let selectedProfile else { return }
        defer { scheduleAppRulesUpdate() }
        vpn.saveSelection(
            profileName: selectedProfile,
            // Keep the app choices while switching modes: All apps and
            // Browser only ignore this list when building tunnel rules, so
            // going back to a selected-app mode keeps them.
            appIdentifiers: Array(selectedApps),
            routingMode: routingMode,
            appEntries: Array(addedApps.values)
        )
    }

    /// Shows an open panel as a sheet on the key window, or as a dialog.
    static func present(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow, !(window is NSPanel) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    // MARK: - Previews

    #if DEBUG
    struct Preview {
        var status: NEVPNStatus = .disconnected
        var profiles: [(name: String, meta: ProfileMeta)] = []
        var routingMode: SharedConfig.RoutingMode = .allApps
        var apps: [(entry: AppEntry, enabled: Bool)] = []
        var domains: [(name: String, subdomains: Bool, enabled: Bool)] = []
        var blockWhenDisconnected = false
        var diagnostics = Diagnostics()
        var listKind: ListKind = .apps
        var listSearch = ""
        /// The running tunnel's routing; differs from the above for pending changes.
        var appliedRouting: SharedConfig.AppliedRouting?
    }

    /// Sample data for UI snapshots; touches nothing on the system.
    init(preview: Preview) {
        vpn = VPNManager(previewStatus: preview.status, appliedRouting: preview.appliedRouting)
        isPreview = true
        profiles = preview.profiles.map(\.name)
        previewMeta = Dictionary(uniqueKeysWithValues: preview.profiles.map { ($0.name, $0.meta) })
        selectedProfile = profiles.first
        routingMode = preview.routingMode
        addedApps = Dictionary(uniqueKeysWithValues: preview.apps.map { ($0.entry.bundleIdentifier, $0.entry) })
        selectedApps = Set(preview.apps.filter(\.enabled).map(\.entry.bundleIdentifier))
        previewIcons = Dictionary(uniqueKeysWithValues: preview.apps.map {
            ($0.entry.bundleIdentifier, NSWorkspace.shared.icon(forFile: $0.entry.path))
        })
        domains = preview.domains.map(\.name)
        subdomainDomains = Set(preview.domains.filter(\.subdomains).map(\.name))
        inactiveDomains = Set(preview.domains.filter { !$0.enabled }.map(\.name))
        blockWhenDisconnected = preview.blockWhenDisconnected
        diagnostics = preview.diagnostics
        listKind = preview.listKind
        listSearch = preview.listSearch
        // The preview window's simulated connection changes the VPN's state.
        vpn.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
    #endif
}

extension SharedConfig.RoutingMode {
    /// The name in the "Use VPN for" picker.
    var choiceTitle: String {
        switch self {
        case .allApps: return "All Apps"
        case .selectedAppsOnly: return "Selected Apps"
        case .selectedAppsAndBrowser: return "Apps and Websites"
        case .browserOnly: return "Websites Only"
        }
    }

    var choiceDetail: String {
        switch self {
        case .allApps: return "All traffic from this Mac uses the VPN."
        case .selectedAppsOnly: return "Only the apps you switch on use the VPN."
        case .selectedAppsAndBrowser: return "The apps you switch on and the websites you list use the VPN."
        case .browserOnly: return "Only the websites you list use the VPN, in Chrome and other Chromium browsers."
        }
    }
}

/// Profiles parsed for display, cached so views do not hit the disk and the
/// parser on every render. Invalidated on import and delete.
final class ProfileCatalog {
    static let shared = ProfileCatalog()

    struct Entry {
        let text: String
        let profile: OVPNProfile?
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func entry(for name: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[name] { return cached }
        guard let text = SharedConfig.loadProfile(name: name) else { return nil }
        let entry = Entry(text: text, profile: try? OVPNParser().parse(text))
        entries[name] = entry
        return entry
    }

    func invalidate() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
