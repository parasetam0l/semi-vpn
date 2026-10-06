import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window, with its tabs in the toolbar. An AppKit window so it
/// opens the same way from the main window, the menu bar panel and ⌘,.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    enum Tab: Int, CaseIterable {
        case general, profiles, browser, diagnostics

        var title: String {
            switch self {
            case .general: return "General"
            case .profiles: return "Profiles"
            case .browser: return "Browser"
            case .diagnostics: return "Diagnostics"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .profiles: return "doc.text"
            case .browser: return "puzzlepiece.extension"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    private let tabs = NSTabViewController()

    private init() {
        tabs.tabStyle = .toolbar
        for tab in Tab.allCases {
            let host = NSHostingController(rootView: SettingsTabView(tab: tab).environmentObject(AppModel.shared))
            host.sizingOptions = [.preferredContentSize]
            // The tab controller passes the selected tab's title on to the
            // window; without one, the window is "Untitled".
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ tab: Tab? = nil) {
        if let tab {
            tabs.selectedTabViewItemIndex = tab.rawValue
        }
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// One tab of Settings.
struct SettingsTabView: View {
    let tab: SettingsWindowController.Tab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings()
            case .profiles: ProfilesSettings()
            case .browser: BrowserSettings()
            case .diagnostics: DiagnosticsSettings()
            }
        }
        .padding(20)
        .frame(width: 500, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updater = AppUpdater.shared
    @State private var launchAtLogin = AppDelegate.shared?.launchAtLoginEnabled ?? false
    @State private var launchAtLoginError: String?
    @State private var connectAtLaunch = AppDelegate.shared?.connectAtLaunchEnabled ?? false
    @State private var detailedLogging = AppLogger.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionBox(footer: loginFooter) {
                SectionRow(first: true) {
                    Text("Open SemiVPN at login")
                    Spacer()
                    Toggle("Open SemiVPN at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if launchAtLogin {
                    SectionRow {
                        Text("Connect automatically at startup")
                        Spacer()
                        Toggle("Connect automatically at startup", isOn: Binding(
                            get: { connectAtLaunch },
                            set: {
                                connectAtLaunch = $0
                                AppDelegate.shared?.setConnectAtLaunch($0)
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
            SectionBox(title: "Updates", footer: updatesFooter) {
                SectionRow(first: true) {
                    Text("Check for updates automatically")
                    Spacer()
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!updater.isAvailable)
                }
                SectionRow {
                    Text("SemiVPN \(AppUpdater.currentVersion)")
                    Spacer()
                    Button("Check Now", action: updater.checkForUpdates)
                        .controlSize(.small)
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            SectionBox(title: "Websites", footer: model.blockWhenDisconnected
                       ? "Listed websites never use your regular connection: they don’t load until the VPN is connected."
                       : "Listed websites use your regular connection while the VPN is disconnected.") {
                SectionRow(first: true) {
                    Text("Block listed websites while disconnected")
                    Spacer()
                    Toggle("Block listed websites while disconnected", isOn: Binding(
                        get: { model.blockWhenDisconnected },
                        set: { model.setBlockWhenDisconnected($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            SectionBox(title: "Logs", footer: AppLogger.logURL?.path) {
                SectionRow(first: true) {
                    Text("Detailed logging")
                    Spacer()
                    Toggle("Detailed logging", isOn: $detailedLogging)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: detailedLogging) { _, on in
                            AppLogger.enabled = on
                            AppLogger.log("extensive logging \(on ? "enabled" : "disabled")")
                        }
                }
                SectionRow {
                    Text("Log file")
                    Spacer()
                    Button("Show in Finder", action: model.revealLogFile)
                        .controlSize(.small)
                }
            }
        }
    }

    private var loginFooter: String {
        if let launchAtLoginError { return launchAtLoginError }
        guard let appDelegate = AppDelegate.shared else {
            return "SemiVPN keeps running in the menu bar when you close its window."
        }
        guard launchAtLogin, connectAtLaunch, SMAppService.mainApp.status == .enabled else {
            return appDelegate.launchAtLoginStatusDescription
        }
        let profile = model.lastConnectedProfile.map { "“\(model.profileMeta($0).displayName)”" }
        return "SemiVPN opens when you log in, keeps running in the menu bar and connects to "
            + (profile.map { "\($0), the profile you connected to last." } ?? "the profile you connected to last.")
    }

    private var updatesFooter: String {
        guard updater.isAvailable else { return "Development builds don’t check for updates." }
        let last = updater.lastCheck.map { "Last checked " + BrowserExtensionPanel.relative($0) + ". " } ?? ""
        return last + "Updates come from SemiVPN’s GitHub releases. SemiVPN asks before installing one."
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard let appDelegate = AppDelegate.shared else { return }
        switch appDelegate.setLaunchAtLogin(enabled) {
        case .success:
            launchAtLogin = enabled
            launchAtLoginError = nil
        case .failure(let error):
            launchAtLogin = appDelegate.launchAtLoginEnabled
            launchAtLoginError = error.localizedDescription
        }
    }
}

// MARK: - Profiles

private struct ProfilesSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var showScan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionBox(footer: "Each profile is named after its certificate. SemiVPN checks the file and keeps a private copy, so you can delete the original.") {
                if model.profiles.isEmpty {
                    SectionRow(first: true) {
                        Text("No profiles yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                if model.profiles.count > 6 {
                    ScrollView {
                        profileRows
                    }
                    .frame(height: 300)
                } else {
                    profileRows
                }
            }
            HStack(spacing: 8) {
                Button("Import Profile…", action: model.showProfilePicker)
                Button("Find Profiles on This Mac…") { showScan = true }
                Spacer()
            }
        }
        .sheet(isPresented: $showScan) {
            ProfileScanSheet { urls in model.importProfiles(urls) }
        }
        .sheet(item: $model.credentialEditor) { request in
            CredentialPrompt(request: request, purpose: .save) { credentials, _ in
                model.saveCredentials(credentials, for: request)
            } onCancel: {
                model.credentialEditor = nil
            } onForget: {
                model.forgetCredentials(for: request)
            }
        }
    }

    private var profileRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.profiles.enumerated()), id: \.element) { index, name in
                profileRow(name, first: index == 0)
            }
        }
    }

    private func profileRow(_ name: String, first: Bool) -> some View {
        let meta = model.profileMeta(name)
        let inUse = name == model.selectedProfile
        return SectionRow(first: first) {
            Image(systemName: inUse ? "checkmark.circle.fill" : "doc.text")
                .foregroundStyle(inUse ? SemiTheme.brand : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(meta.displayName)
                    .lineLimit(1)
                Text("\(meta.host) · \(meta.protocolName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if inUse {
                Text("In Use")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("Use") { model.chooseProfile(name) }
                    .controlSize(.small)
            }
            if let request = model.credentialRequest(for: name) {
                Button {
                    model.credentialEditor = request
                } label: {
                    Image(systemName: model.hasSavedCredentials(name) ? "key.fill" : "key")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Saved credentials")
            }
            Button {
                model.deleteProfile(name)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete profile")
        }
    }
}

// MARK: - Browser

private struct BrowserSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BrowserExtensionPanel(monitor: ExtensionMonitor.shared)
            Text("Chrome and other Chromium browsers send the websites you list to SemiVPN at 127.0.0.1:\(String(SharedConfig.localProxyPort)); everything else connects directly.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var extensionMonitor = ExtensionMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionBox(footer: "Use these when a connection or routing doesn’t work as expected.") {
                row("Network extension", detail: model.diagnostics.tunnelRegistered ? "Installed and enabled" : "Not enabled",
                    ok: model.diagnostics.tunnelRegistered, first: true)
                row("VPN configuration", detail: model.diagnostics.vpnConfigSaved ? "Saved" : "Not saved yet",
                    ok: model.diagnostics.vpnConfigSaved)
                row("Selected-app rules", detail: model.diagnostics.perAppConfigSaved ? "Saved" : "None",
                    ok: model.diagnostics.perAppConfigSaved || !model.routingMode.requiresSelectedApps)
                row("Connection", detail: model.connectionStatusText, ok: model.vpn.status == .connected)
                row("Browser routing", detail: extensionMonitor.browserRoutingBroken ? "Outside the VPN" : "OK",
                    ok: !extensionMonitor.browserRoutingBroken)
            }
            HStack(spacing: 8) {
                Button("Check Again", action: model.refreshDiagnostics)
                Button("Repair VPN Routing…", action: model.repairVPNRouting)
                    .disabled(model.routingRepairPhase.isBusy)
                    .help("Clears macOS’s per-app VPN record and restarts its VPN service. Asks for your administrator password.")
                Spacer()
            }
        }
        .onAppear(perform: model.refreshDiagnostics)
    }

    private func row(_ title: String, detail: String, ok: Bool, first: Bool = false) -> some View {
        SectionRow(first: first) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? SemiTheme.green : SemiTheme.amber)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }
}
