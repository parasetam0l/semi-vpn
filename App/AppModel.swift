import AppKit
import Combine
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
    @Published private(set) var diagnostics = Diagnostics()

    /// Presented by the window.
    @Published var connectError: String?
    @Published var credentialEditor: VPNManager.CredentialRequest?

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
        if connecting && (vpn.status == .disconnected || vpn.status == .invalid) {
            return .connecting
        }
        return vpn.status
    }

    var isConnected: Bool { displayedStatus == .connected }

    var isTunnelActive: Bool {
        let status = displayedStatus
        return status == .connected || status == .connecting || status == .reasserting
    }

    /// Profile, routing mode and apps can't change while the tunnel is up or
    /// changing; websites can.
    var configurationLocked: Bool {
        connecting || vpn.status == .connected || vpn.status == .connecting
            || vpn.status == .reasserting || vpn.status == .disconnecting
    }

    var statusTitle: String {
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
        guard profiles.contains(name), name != selectedProfile, !configurationLocked else { return }
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
            if !configurationLocked {
                selectedProfile = name + ".ovpn"
                saveCurrentSelection()
            }
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
        guard mode != routingMode, !configurationLocked else { return }
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
        guard !configurationLocked else { return }
        if enabled {
            selectedApps.insert(app.bundleIdentifier)
        } else {
            selectedApps.remove(app.bundleIdentifier)
            selectedApps.remove(app.signingIdentifier)
        }
        saveCurrentSelection()
    }

    func removeApp(_ app: AppEntry) {
        guard !configurationLocked else { return }
        addedApps.removeValue(forKey: app.bundleIdentifier)
        selectedApps.remove(app.bundleIdentifier)
        selectedApps.remove(app.signingIdentifier)
        saveCurrentSelection()
        AppLogger.log("removed app \(app.name)")
    }

    func appIcon(_ app: AppEntry) -> NSImage {
        previewIcons[app.bundleIdentifier] ?? NSWorkspace.shared.icon(forFile: app.path)
    }

    func showAppPicker() {
        guard !isPreview, !configurationLocked else { return }
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
                guard let bundle = Bundle(url: url),
                      let identifier = bundle.bundleIdentifier else { continue }
                let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                self.addedApps[identifier] = AppEntry(
                    name: name,
                    bundleIdentifier: identifier,
                    signingIdentifier: identifier,
                    path: url.path,
                    designatedRequirement: AppCodeSignature.designatedRequirement(for: url)
                )
                self.selectedApps.insert(identifier)
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

    func removeDomain(_ domain: String) {
        guard !isPreview else { return }
        do {
            apply(try SharedConfig.removeDomain(domain))
            AppLogger.log("removed domain rule: \(domain)")
        } catch {
            AppLogger.log("removing domain rule failed: \(error.localizedDescription)")
        }
    }

    func setDomainEnabled(_ domain: String, enabled: Bool) {
        guard !isPreview else { return }
        do {
            apply(try SharedConfig.setDomainEnabled(domain, enabled: enabled))
            AppLogger.log("domain rule \(enabled ? "enabled" : "paused"): \(domain)")
        } catch {
            AppLogger.log("updating domain rule failed: \(error.localizedDescription)")
        }
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

    // MARK: - Connection

    func connect(credentials: TunnelSecrets.Credentials? = nil, remember: Bool = false) {
        guard !isPreview, let selectedProfile, !connecting else { return }
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
        guard !isPreview else { return }
        vpn.stop()
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

    private func saveCurrentSelection() {
        guard !isPreview, let selectedProfile else { return }
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
    }

    /// Sample data for UI snapshots; touches nothing on the system.
    init(preview: Preview) {
        vpn = VPNManager(previewStatus: preview.status)
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
    }
    #endif
}

extension SharedConfig.RoutingMode {
    /// The name in the "Use VPN for" picker.
    var choiceTitle: String {
        switch self {
        case .allApps: return "All Apps"
        case .selectedAppsOnly: return "Selected Apps"
        case .selectedAppsAndBrowser: return "Selected Apps and Websites"
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
