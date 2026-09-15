import Foundation
import AppKit
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

    private let tunnelProviderBundleIdentifier = "com.semivpn.app.TunnelProvider"
    private let proxyHelperBundleIdentifier = "com.semivpn.proxy"
    private var proxyHelperProcess: Process?
    private var statusObserver: NSObjectProtocol?
    private var distributedConnectObserver: NSObjectProtocol?
    private var distributedDisconnectObserver: NSObjectProtocol?
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
        ensureProxyHelperRunning()
        loadSelection()
        updateProxyAvailability()
        distributedConnectObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.semivpn.app.requestConnect"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                AppLogger.log("distributed: connect requested")
                try? await self?.start()
            }
        }
        distributedDisconnectObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.semivpn.app.requestDisconnect"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            AppLogger.log("distributed: disconnect requested")
            self?.stop()
        }
        Task { [weak self] in
            await self?.restoreSavedManagerStatus()
        }
    }

    deinit {
        stopProxyHelper()
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        if let distributedConnectObserver {
            DistributedNotificationCenter.default().removeObserver(distributedConnectObserver)
        }
        if let distributedDisconnectObserver {
            DistributedNotificationCenter.default().removeObserver(distributedDisconnectObserver)
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
    func start() async throws {
        SharedConfig.ensureDirectories()
        AppLogger.log("start: begin")

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

        let profile: OVPNProfile
        do {
            profile = try OVPNParser().parse(profileText)
        } catch {
            throw NSError(domain: "com.semivpn.app", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid profile: \(error.localizedDescription)"])
        }
        let serverAddress = profile.remotes.first?.host ?? "semi-vpn"

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
        tunnelProtocol.providerConfiguration = [
            SharedConfig.profileKey: profileText,
            SharedConfig.selectionKey: selection.appIdentifiers,
            SharedConfig.fullTunnelKey: selection.fullTunnel,
            SharedConfig.domainRoutingKey: selection.domainRouting,
            SharedConfig.routingModeKey: selection.routingMode.rawValue,
            SharedConfig.nativePerAppKey: wantsPerApp,
        ]
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

        do {
            try tunnelManager.connection.startVPNTunnel()
            AppLogger.log("start: packet tunnel started")
        } catch {
            AppLogger.log("start: tunnel start error: \(error) — retrying after propagation")
            try? await tunnelManager.loadFromPreferences()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try tunnelManager.connection.startVPNTunnel()
            AppLogger.log("start: packet tunnel started after retry")
        }
    }

    func stop() {
        AppLogger.log("disconnect requested")
        guard let manager = tunnelManager else { return }

        Task {
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
        }
        status = manager.connection.status
        updateProxyAvailability()
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

    private var activeProfileHasIPv6: Bool {
        guard let selection,
              let profileText = SharedConfig.loadProfile(name: selection.profileName),
              let profile = try? OVPNParser().parse(profileText) else {
            return false
        }
        return profile.ifconfigIPv6Local != nil
    }

    private func updateProxyAvailability() {
        let isForwardingAllowed = status == .connected && (selection?.domainRouting == true || selection?.routingMode.includesBrowser == true)
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
