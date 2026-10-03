import Foundation
import AppKit
import Combine
import CoreServices
import NetworkExtension
import OpenVPNCore

/// Configures the packet tunnel for full-tunnel routing or Apple's native
/// macOS per-app VPN routing. Browser-domain routing is part of the selected
/// routing mode: browser-enabled per-app modes add the SemiVPN host app as a
/// helper rule for the localhost proxy.
///
/// Selected-app mode deliberately uses `NETunnelProviderManager.forPerAppVPN`
/// and `NEAppRule`. The packet provider then receives packets from the apps
/// selected by macOS, instead of the app-proxy extension having to intercept
/// and splice each socket itself.
final class VPNManager: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var selection: SharedConfig.Selection?
    @Published var hasSavedConfiguration = false
    /// The reason the tunnel last stopped on its own (e.g. authentication
    /// failed), for the UI.
    @Published var lastError: String?
    /// Set when connecting needs credentials the app does not have; the UI
    /// prompts and calls `start(credentials:remember:)` again.
    @Published var credentialRequest: CredentialRequest?
    /// The routing in the saved VPN configuration: what the tunnel runs
    /// (macOS also uses it for on-demand starts). Changes to the selection
    /// made meanwhile apply at the next start.
    @Published private(set) var appliedRouting: SharedConfig.AppliedRouting?
    /// True while reconnect() stops and starts the tunnel, and while the
    /// tunnel restarts after an update replaced the network extension.
    @Published private(set) var isReconnecting = false
    /// Sent when macOS stopped the tunnel to replace the network extension
    /// with a new build; the app starts it again unless per-app on-demand
    /// does first (see endExtensionUpdateRestart()).
    let stoppedForExtensionUpdate = PassthroughSubject<Void, Never>()
    /// Credentials entered for this connection without saving them, so a
    /// reconnect doesn't ask again. Cleared by Disconnect.
    private var sessionCredentials: (credentials: TunnelSecrets.Credentials, remember: Bool)?

    /// What a profile needs before it can connect.
    struct CredentialRequest: Identifiable, Equatable {
        let profileName: String
        let needsUsernamePassword: Bool
        let needsKeyPassphrase: Bool
        var username: String?
        var id: String { profileName }
    }

    enum StartError: LocalizedError {
        case credentialsRequired(CredentialRequest)

        var errorDescription: String? {
            switch self {
            case .credentialsRequired(let request):
                if request.needsUsernamePassword && request.needsKeyPassphrase {
                    return "Enter the username, password and private-key passphrase for this profile."
                }
                return request.needsUsernamePassword
                    ? "Enter the username and password for this profile."
                    : "Enter the passphrase of this profile's private key."
            }
        }
    }

    /// Whether the credentials used for the running tunnel may stay in the
    /// shared keychain item after disconnecting.
    private var keepCredentialsAfterStop = true
    /// Set by `stop()`: a disconnect the user asked for is not an error.
    private var userRequestedStop = false
    /// An update replacing the network extension: macOS stops a running
    /// tunnel to swap the extension, which is not a failure.
    private enum ExtensionUpdate: Equatable {
        /// macOS is replacing it; the tunnel's stop is still to come.
        case replacing(since: Date)
        /// The tunnel stopped for it and is starting again.
        case restarting
    }
    private var extensionUpdate: ExtensionUpdate?

    private let tunnelProviderBundleIdentifier = "com.semivpn.app.TunnelProvider"
    private let proxyHelperBundleIdentifier = "com.semivpn.proxy"
    private var proxyHelperProcess: Process?
    private var statusObserver: NSObjectProtocol?
    private var tunnelManager: NETunnelProviderManager?

    static var proxyHelperAppURL: URL? {
        let bundleURL = Bundle.main.bundleURL
        let helperURL = bundleURL.appendingPathComponent("Contents/Resources/SemiProxy.app")
        if FileManager.default.fileExists(atPath: helperURL.path) {
            return helperURL
        }
        let devURL = bundleURL.deletingLastPathComponent().appendingPathComponent("SemiProxy.app")
        if FileManager.default.fileExists(atPath: devURL.path) {
            return devURL
        }
        return nil
    }

    static var proxyHelperExecutableURL: URL? {
        proxyHelperAppURL?.appendingPathComponent("Contents/MacOS/SemiProxy")
    }

    func ensureProxyHelperRunning() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: proxyHelperBundleIdentifier)
        if running.contains(where: { !$0.isTerminated }) {
            return
        }

        guard let helperURL = Self.proxyHelperAppURL,
              FileManager.default.fileExists(atPath: helperURL.path) else {
            AppLogger.log("proxy helper: app bundle not found at \(Self.proxyHelperAppURL?.path ?? "nil")")
            return
        }

        // Register the helper app bundle with LaunchServices so macOS NECP maps its bundle identifier
        _ = LSRegisterURL(helperURL as CFURL, true)

        let parentPID = ProcessInfo.processInfo.processIdentifier
        var args = ["--parent-pid", "\(parentPID)"]
        if AppLogger.enabled {
            args.append("--extensive-logging")
        }

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = args
        config.activates = false
        config.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: helperURL, configuration: config) { app, error in
            if let error = error {
                AppLogger.log("proxy helper: NSWorkspace launch failed (\(error)), attempting fallback with /usr/bin/open")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", helperURL.path, "--args"] + args
                do {
                    try process.run()
                    AppLogger.log("proxy helper: launched via /usr/bin/open")
                } catch {
                    AppLogger.log("proxy helper: fallback launch failed: \(error)")
                }
            } else if let app = app {
                AppLogger.log("proxy helper: launched via NSWorkspace pid \(app.processIdentifier)")
            }
        }
    }

    func stopProxyHelper() {
        if let proc = proxyHelperProcess, proc.isRunning {
            proc.terminate()
            proxyHelperProcess = nil
        }
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: proxyHelperBundleIdentifier)
        for app in existing {
            app.forceTerminate()
        }
        if !existing.isEmpty {
            AppLogger.log("proxy helper: terminated \(existing.count) instance(s)")
        }
    }

    func restartProxyHelper() {
        stopProxyHelper()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.ensureProxyHelperRunning()
        }
    }

    init() {
        appliedRouting = SharedConfig.loadAppliedRouting()
        ensureProxyHelperRunning()
        loadSelection()
        updateProxyAvailability()
        Task { [weak self] in
            await self?.restoreSavedManagerStatus()
        }
    }

    #if DEBUG
    /// For UI snapshots: starts nothing, reads nothing, stops nothing.
    init(previewStatus: NEVPNStatus, appliedRouting: SharedConfig.AppliedRouting? = nil) {
        isPreview = true
        status = previewStatus
        hasSavedConfiguration = true
        self.appliedRouting = appliedRouting
    }
    #endif

    /// A preview instance must never stop the real proxy helper.
    private var isPreview = false

    deinit {
        if !isPreview {
            stopProxyHelper()
        }
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func loadSelection() {
        selection = SharedConfig.loadSelection()
    }

    func saveSelection(profileName: String, appIdentifiers: [String], fullTunnel: Bool,
                       appEntries: [AppEntry] = [], domainRouting: Bool = false) {
        let newSelection = SharedConfig.Selection(
            profileFileName: profileName,
            appIdentifiers: appIdentifiers,
            fullTunnel: fullTunnel,
            appEntries: appEntries,
            domainRouting: domainRouting
        )
        SharedConfig.saveSelection(newSelection)
        selection = newSelection
        updateProxyAvailability()
        NotificationCenter.default.post(name: SharedConfig.selectionDidChangeNotification, object: nil)
    }

    func saveSelection(profileName: String, appIdentifiers: [String],
                       routingMode: SharedConfig.RoutingMode,
                       appEntries: [AppEntry] = []) {
        let newSelection = SharedConfig.Selection(
            profileFileName: profileName,
            appIdentifiers: appIdentifiers,
            routingMode: routingMode,
            appEntries: appEntries
        )
        SharedConfig.saveSelection(newSelection)
        selection = newSelection
        updateProxyAvailability()
        NotificationCenter.default.post(name: SharedConfig.selectionDidChangeNotification, object: nil)
    }

    /// Configures and starts the packet tunnel. In selected-app mode the
    /// system scopes the packet tunnel to `NEAppRule`s; in all-apps mode the
    /// same provider installs the normal default route.
    /// - Parameter credentials: entered by the user for this connection;
    ///   saved credentials are used when nil.
    /// - Parameter remember: save the entered credentials in the keychain.
    func start(credentials: TunnelSecrets.Credentials? = nil, remember: Bool = false) async throws {
        SharedConfig.ensureDirectories()
        AppLogger.log("start: begin")
        await MainActor.run {
            self.lastError = nil
            self.userRequestedStop = false
        }

        guard let selection,
              let profileText = SharedConfig.loadProfile(name: selection.profileName) else {
            throw NSError(domain: "com.semivpn.app", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No profile selected"])
        }

        if selection.routingMode.requiresSelectedApps && selection.appIdentifiers.isEmpty {
            throw NSError(domain: "com.semivpn.app", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Select at least one application for this routing mode."])
        }

        let appRules = try makeAppRules(for: selection)
        // The tunnel provider is a system extension: it must be installed
        // (and, the first time, allowed by the user) before it can start.
        try await SystemExtensionInstaller.shared.ensureActive()

        let profile: OVPNProfile
        do {
            profile = try OVPNParser().parse(profileText)
        } catch {
            throw NSError(domain: "com.semivpn.app", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid profile: \(error.localizedDescription)"])
        }
        let serverAddress = profile.remotes.first?.host ?? "semi-vpn"

        // Credentials: inline <auth-user-pass>, entered now, or saved.
        let saved = CredentialStore.load(profile: selection.profileName)
        let effective = credentials ?? saved ?? TunnelSecrets.Credentials()
        let needsUserPass = profile.requiresAuthUserPass && profile.authUserPass?.password == nil
            && ((effective.username ?? "").isEmpty || effective.password == nil)
        let needsPassphrase = profile.requiresKeyPassphrase && (effective.keyPassphrase ?? "").isEmpty
        if needsUserPass || needsPassphrase {
            let request = CredentialRequest(
                profileName: selection.profileName,
                needsUsernamePassword: profile.requiresAuthUserPass && profile.authUserPass?.password == nil,
                needsKeyPassphrase: profile.requiresKeyPassphrase,
                username: effective.username ?? saved?.username
            )
            await MainActor.run { self.credentialRequest = request }
            throw StartError.credentialsRequired(request)
        }
        if let credentials, remember {
            CredentialStore.save(credentials, profile: selection.profileName)
        }
        if let credentials {
            sessionCredentials = (credentials, remember)
        }
        keepCredentialsAfterStop = credentials == nil || remember

        let existingTunnels = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        let wantsPerApp = !selection.fullTunnel
        let modeName = wantsPerApp ? "per-app" : "all-apps"
        AppLogger.log("start: loaded \(existingTunnels.count) tunnel configs; mode=\(modeName)")

        // A per-app manager is a different Network Extension configuration
        // kind from a normal destination-routed manager, so select the right
        // saved configuration or create the appropriate kind.
        let matchingTunnels = existingTunnels.filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == tunnelProviderBundleIdentifier
        }
        let tunnelManager = matchingTunnels.first(where: {
            (wantsPerApp && $0.routingMethod == .sourceApplication) ||
            (!wantsPerApp && $0.routingMethod != .sourceApplication)
        }) ?? (wantsPerApp ? NETunnelProviderManager.forPerAppVPN() : NETunnelProviderManager())

        // Do not leave the other routing-kind configuration enabled. It can
        // otherwise compete with the configuration being started after a mode
        // switch. Keep the disabled object in preferences so switching modes
        // does not create a new VPN configuration and show the consent dialog
        // again.
        for stale in matchingTunnels where stale !== tunnelManager {
            stale.connection.stopVPNTunnel()
            stale.isOnDemandEnabled = false
            stale.isEnabled = false
            // Do not leave secrets of older builds (or the no-keychain
            // fallback) in the unencrypted VPN preferences.
            if let staleProtocol = stale.protocolConfiguration as? NETunnelProviderProtocol {
                var configuration = staleProtocol.providerConfiguration ?? [:]
                for key in [SharedConfig.profileKey, TunnelSecrets.usernameKey,
                            TunnelSecrets.passwordKey, TunnelSecrets.keyPassphraseKey] {
                    configuration.removeValue(forKey: key)
                }
                staleProtocol.providerConfiguration = configuration
                stale.protocolConfiguration = staleProtocol
            }
            do {
                try await stale.saveToPreferences()
                AppLogger.log("start: disabled stale \(stale.routingMethod == .sourceApplication ? "per-app" : "all-apps") tunnel config")
            } catch {
                AppLogger.log("start: stale tunnel cleanup failed: \(error)")
            }
        }

        tunnelManager.localizedDescription = wantsPerApp ? "SemiVPN selected apps" : "SemiVPN tunnel"
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = tunnelProviderBundleIdentifier
        tunnelProtocol.serverAddress = serverAddress
        // Keep the provider alive through sleep so its wake() callback can
        // rebuild the raw OpenVPN transport on the resumed physical network.
        tunnelProtocol.disconnectOnSleep = false
        var providerConfiguration: [String: Any] = [
            SharedConfig.selectionKey: selection.appIdentifiers,
            SharedConfig.fullTunnelKey: selection.fullTunnel,
            SharedConfig.domainRoutingKey: selection.domainRouting,
            SharedConfig.routingModeKey: selection.routingMode.rawValue,
            SharedConfig.nativePerAppKey: wantsPerApp,
        ]
        // The profile (private key) and credentials travel with the start
        // request instead (see TunnelSecrets): the VPN preferences are stored
        // unencrypted on disk.
        tunnelProtocol.providerConfiguration = providerConfiguration
        tunnelManager.protocolConfiguration = tunnelProtocol
        if wantsPerApp {
            tunnelManager.appRules = appRules
            // Native macOS per-app VPN rules are fail-closed while the
            // provider is disconnected. Enable the built-in per-app
            // on-demand behavior so a selected app's first network request
            // starts this tunnel instead of being left on a dead utun.
            tunnelManager.isOnDemandEnabled = true
            AppLogger.log("start: configured \(appRules.count) native app rules")
            AppLogger.log("start: per-app on-demand enabled")
        } else {
            tunnelManager.isOnDemandEnabled = false
        }
        tunnelManager.isEnabled = true
        do {
            try await tunnelManager.saveToPreferences()
            // Apple documents a configuration as stale until it is loaded
            // again after saving. Reload the object before starting, which is
            // especially important when switching between source-app and
            // destination-IP routing.
            try await tunnelManager.loadFromPreferences()
        } catch {
            AppLogger.log("start: packet tunnel config save failed: \(error)")
            if wantsPerApp {
                throw NSError(
                    domain: "com.semivpn.app",
                    code: 6,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "macOS rejected the native selected-app VPN configuration. " +
                            "Development builds need Apple's per-app VPN test configuration; " +
                            "production builds need an MDM per-app VPN profile. " +
                            "Underlying error: \(error.localizedDescription)"
                    ]
                )
            }
            throw error
        }
        AppLogger.log("start: packet tunnel config saved")
        AppLogger.log("start: routingMethod=\(tunnelManager.routingMethod.rawValue) savedRules=\(tunnelManager.copyAppRules()?.count ?? 0)")

        self.tunnelManager = tunnelManager
        hasSavedConfiguration = true
        restartProxyHelper()
        updateProxyAvailability()
        observe(tunnelManager)

        // The system needs a moment to propagate the saved configuration;
        // starting immediately can otherwise be rejected as configuration
        // invalid, especially after changing routing kind.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let options = TunnelSecrets.startOptions(
            profileText: profileText, credentials: effective, remember: keepCredentialsAfterStop
        )
        do {
            try Self.startTunnel(tunnelManager, options: options)
            AppLogger.log("start: packet tunnel started")
        } catch {
            AppLogger.log("start: tunnel start error: \(error) — retrying after propagation")
            try? await tunnelManager.loadFromPreferences()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try Self.startTunnel(tunnelManager, options: options)
            AppLogger.log("start: packet tunnel started after retry")
        }
        let applied = SharedConfig.AppliedRouting(selection: selection)
        SharedConfig.saveAppliedRouting(applied)
        await MainActor.run {
            self.appliedRouting = applied
            self.updateProxyAvailability()
        }
    }

    /// Applies the current selection to a running tunnel: macOS uses new
    /// app rules (and a new profile or route) only when the tunnel starts
    /// again. Credentials entered for this connection are used again.
    func reconnect() async throws {
        AppLogger.log("reconnect requested")
        await MainActor.run { self.isReconnecting = true }
        do {
            await stopTunnel()
            try await start(credentials: sessionCredentials?.credentials,
                            remember: sessionCredentials?.remember ?? false)
            await MainActor.run { self.isReconnecting = false }
        } catch {
            await MainActor.run { self.isReconnecting = false }
            throw error
        }
    }

    /// Called on the main thread when macOS is about to replace the network
    /// extension with a new build (the app was updated), which stops a
    /// running tunnel.
    func extensionWillBeReplaced() {
        // .invalid: the configuration hasn't loaded yet at launch, so the
        // tunnel may be running.
        guard status != .disconnected else { return }
        let since = Date()
        extensionUpdate = .replacing(since: since)
        if [.connected, .connecting, .reasserting].contains(status) {
            isReconnecting = true
        }
        AppLogger.log("system extension: replacing it stops a running tunnel")
        // No stop comes when the tunnel wasn't running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.extensionUpdate == .replacing(since: since) else { return }
            self.endExtensionUpdate()
        }
    }

    /// After a stop for an extension update: true when the tunnel is still
    /// down and nobody stopped it (per-app on-demand starts it again by
    /// itself, All Apps doesn't), so the caller should connect again.
    func endExtensionUpdateRestart() -> Bool {
        guard extensionUpdate == .restarting, status == .disconnected, !userRequestedStop else { return false }
        endExtensionUpdate()
        return true
    }

    private func endExtensionUpdate() {
        guard extensionUpdate != nil else { return }
        extensionUpdate = nil
        isReconnecting = false
    }

    /// Whether macOS applies app rules saved into a running per-app
    /// configuration right away. Tested on macOS 27: an added app used the
    /// VPN 4 seconds after the save, without a reconnect. Apple's DTS said in
    /// 2022 (macOS 12) that a restart was needed, and versions in between are
    /// untested, so there the app keeps asking for a reconnect.
    static let appliesAppRulesLive = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    )

    /// Writes the current app rules into the running per-app configuration
    /// after the apps changed (not the profile or the route, which need a
    /// reconnect). Where macOS applies them at once, they become the
    /// applied routing.
    func saveAppRulesToRunningConfiguration() async {
        guard let manager = tunnelManager, manager.routingMethod == .sourceApplication,
              let selection, let applied = appliedRouting,
              applied.routingMode == selection.routingMode, applied.profileName == selection.profileName else { return }
        do {
            let rules = try makeAppRules(for: selection)
            try await manager.loadFromPreferences()
            manager.appRules = rules
            try await manager.saveToPreferences()
            AppLogger.log("running configuration: saved \(rules.count) app rules; tunnel status \(manager.connection.status.rawValue)")
            if Self.appliesAppRulesLive {
                let routing = SharedConfig.AppliedRouting(selection: selection)
                SharedConfig.saveAppliedRouting(routing)
                await MainActor.run { self.appliedRouting = routing }
            }
        } catch {
            AppLogger.log("running configuration: saving app rules failed: \(error)")
        }
    }

    private static func startTunnel(_ manager: NETunnelProviderManager, options: [String: NSObject]) throws {
        guard let session = manager.connection as? NETunnelProviderSession else {
            try manager.connection.startVPNTunnel()
            return
        }
        try session.startTunnel(options: options)
    }

    func stop() {
        AppLogger.log("disconnect requested")
        sessionCredentials = nil
        endExtensionUpdate()
        Task {
            await stopTunnel()
        }
    }

    /// Stops the tunnel and waits until it is down (Disconnect, reconnect).
    private func stopTunnel() async {
        guard let manager = tunnelManager else { return }
        userRequestedStop = true

        // An explicit Disconnect must win over per-app On Demand. If the
        // saved source-app configuration stays enabled, the selected app
        // can immediately start the tunnel again on its next request.
        if manager.routingMethod == .sourceApplication {
            manager.isOnDemandEnabled = false
            do {
                try await manager.saveToPreferences()
                AppLogger.log("disconnect: per-app on-demand disabled")
            } catch {
                AppLogger.log("disconnect: could not disable on-demand: \(error)")
            }
        }

        manager.connection.stopVPNTunnel()
        for _ in 0..<50 {
            if manager.connection.status == .disconnected || manager.connection.status == .invalid {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if manager.routingMethod == .sourceApplication {
            // Keep the configuration object so the user-consent prompt
            // is not shown on every future Connect, but disable it while
            // the user has intentionally disconnected.
            manager.isEnabled = false
            do {
                try await manager.saveToPreferences()
                AppLogger.log("disconnect: disabled per-app routing configuration")
            } catch {
                AppLogger.log("disconnect: could not disable per-app configuration: \(error)")
            }
        }

        if self.tunnelManager === manager {
            self.tunnelManager = nil
            self.status = .disconnected
            self.updateProxyAvailability()
            self.restartProxyHelper()
            if let statusObserver {
                NotificationCenter.default.removeObserver(statusObserver)
                self.statusObserver = nil
            }
        }
    }


    /// Restore the manager that macOS may still be running after the app was
    /// relaunched. Without this, the UI starts at `.invalid` and misses status
    /// notifications for an already-connected or On Demand tunnel.
    private func restoreSavedManagerStatus() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        guard let manager = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == tunnelProviderBundleIdentifier
        }) else { return }

        await MainActor.run {
            // A user may have connected before the asynchronous restore
            // completed. In that case start() already installed the correct
            // observer and manager.
            guard self.tunnelManager == nil else { return }
            self.tunnelManager = manager
            self.hasSavedConfiguration = true
            self.observe(manager)
            AppLogger.log("restore: VPN status \(manager.connection.status.rawValue)")
        }
    }

    private func observe(_ manager: NETunnelProviderManager) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let previousStatus = self.status
            let newStatus = manager.connection.status
            self.status = newStatus
            self.updateProxyAvailability()
            AppLogger.log("VPN status: \(newStatus.rawValue)")

            if newStatus == .connected && (previousStatus == .reasserting || previousStatus == .connecting) {
                AppLogger.log("VPN status connected after \(previousStatus.rawValue) — refreshing proxy helper")
                self.restartProxyHelper()
            }
            // NetworkExtension reports .disconnecting before .disconnected for
            // failures too; only a stop the user asked for is not an error.
            if newStatus == .disconnected, previousStatus != .disconnected, !self.userRequestedStop {
                if case .replacing = self.extensionUpdate {
                    // macOS swapped the network extension for the new build
                    // (NEAgentErrorDomain error 2, "plugin was disabled").
                    AppLogger.log("tunnel stopped for the network extension update")
                    self.extensionUpdate = .restarting
                    self.isReconnecting = true
                    self.stoppedForExtensionUpdate.send()
                } else {
                    self.endExtensionUpdate()
                    self.reportLastDisconnectError(manager)
                }
            }
            if newStatus == .connected, self.extensionUpdate == .restarting {
                AppLogger.log("tunnel running again after the network extension update")
                self.endExtensionUpdate()
            }
        }
        status = manager.connection.status
        updateProxyAvailability()
    }

    /// Fetches why the tunnel stopped on its own and shows it; a rejected
    /// password is forgotten so the next connect asks again.
    private func reportLastDisconnectError(_ manager: NETunnelProviderManager) {
        let profileName = selection?.profileName
        manager.connection.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            let message = (error as NSError).localizedDescription
            AppLogger.log("tunnel stopped: \(message)")
            DispatchQueue.main.async {
                if message.hasPrefix("Authentication failed"), let profileName {
                    CredentialStore.forgetPassword(profile: profileName)
                }
                self?.lastError = message
            }
        }
    }

    // MARK: - Native app rules

    private func makeAppRules(for selection: SharedConfig.Selection) throws -> [NEAppRule] {
        guard !selection.fullTunnel else { return [] }
        guard !selection.appIdentifiers.isEmpty || selection.domainRouting else {
            throw NSError(domain: "com.semivpn.app", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Select at least one application for selected-apps mode."])
        }

        let selected = selection.routingMode.requiresSelectedApps
            ? Set(selection.appIdentifiers)
            : []
        let entries = selection.appEntries.filter {
            selected.contains($0.bundleIdentifier) || selected.contains($0.signingIdentifier)
        }
        let represented = Set(entries.flatMap { [$0.bundleIdentifier, $0.signingIdentifier] })
        let missing = selected.subtracting(represented)
        if !missing.isEmpty {
            throw NSError(domain: "com.semivpn.app", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Re-add the selected application(s) so macOS can identify them: \(missing.sorted().joined(separator: ", "))"])
        }

        var rules: [NEAppRule] = []
        for entry in entries {
            // Resolve the current signature on every connection attempt. This
            // matters for ad-hoc test apps and for apps that have updated
            // since they were added to the list.
            let currentRequirement = entry.path.isEmpty
                ? nil
                : AppCodeSignature.designatedRequirement(for: URL(fileURLWithPath: entry.path))
            let requirement = currentRequirement ?? entry.designatedRequirement
            guard let requirement, !requirement.isEmpty else {
                throw NSError(domain: "com.semivpn.app", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Could not read the code signature for \(entry.name). Remove and add it again."])
            }

            let signingIdentifier = entry.signingIdentifier.isEmpty
                ? entry.bundleIdentifier
                : entry.signingIdentifier
            rules.append(NEAppRule(
                signingIdentifier: signingIdentifier,
                designatedRequirement: requirement
            ))
            AppLogger.log("start: app rule \(entry.name) id=\(signingIdentifier)")
        }

        if selection.domainRouting || selection.routingMode.includesBrowser {
            guard let helperURL = Self.proxyHelperAppURL else {
                throw NSError(domain: "com.semivpn.app", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "SemiProxy helper application is missing from app bundle."])
            }
            guard let requirement = AppCodeSignature.designatedRequirement(for: helperURL), !requirement.isEmpty else {
                throw NSError(domain: "com.semivpn.app", code: 8,
                              userInfo: [NSLocalizedDescriptionKey: "Could not read code signature for SemiProxy helper."])
            }
            _ = LSRegisterURL(helperURL as CFURL, true)
            let proxyRule = NEAppRule(
                signingIdentifier: proxyHelperBundleIdentifier,
                designatedRequirement: requirement
            )
            proxyRule.matchDomains = nil
            rules.append(proxyRule)
            AppLogger.log("start: added helper proxy rule (\(proxyHelperBundleIdentifier))")
        }
        return rules
    }

    private var tunnelRunning: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    private var activeProfileHasIPv6: Bool {
        let profileName = (tunnelRunning ? appliedRouting?.profileName : nil) ?? selection?.profileName
        guard let profileName,
              let profileText = SharedConfig.loadProfile(name: profileName),
              let profile = try? OVPNParser().parse(profileText) else {
            return false
        }
        return profile.ifconfigIPv6Local != nil
    }

    private func updateProxyAvailability() {
        // While connected, the routing the tunnel was started with; a change
        // made meanwhile applies when it reconnects.
        let mode = (tunnelRunning ? appliedRouting?.routingMode : nil) ?? selection?.routingMode
        let isForwardingAllowed = status == .connected && mode?.includesBrowser == true
        SharedConfig.saveRuntimeState(SharedConfig.RuntimeState(
            vpnStatus: Self.displayStatus(for: status),
            forwardingAllowed: isForwardingAllowed,
            hasVPNIPv6: activeProfileHasIPv6
        ))
        NotificationCenter.default.post(
            name: SharedConfig.domainConfigurationDidChangeNotification,
            object: nil
        )
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.semivpn.app.domainConfigurationDidChange"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        if status == .connected, let session = tunnelManager?.connection as? NETunnelProviderSession {
            try? session.sendProviderMessage(Data("status".utf8)) { response in
                guard let response,
                      let json = try? JSONSerialization.jsonObject(with: response) as? [String: String] else {
                    return
                }
                let tunnelHasIPv6 = json["hasVPNIPv6"] == "true"
                DispatchQueue.main.async {
                    SharedConfig.saveRuntimeState(SharedConfig.RuntimeState(
                        vpnStatus: Self.displayStatus(for: session.status),
                        forwardingAllowed: isForwardingAllowed,
                        hasVPNIPv6: tunnelHasIPv6
                    ))
                    NotificationCenter.default.post(
                        name: SharedConfig.domainConfigurationDidChangeNotification,
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
        }
    }

    private static func displayStatus(for status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

}
