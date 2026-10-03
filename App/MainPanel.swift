import AppKit
import SwiftUI

/// SemiVPN's one screen: the connection, its profile and route, and the apps
/// or websites that use the VPN. The window shows it, and the menu bar panel
/// shows a condensed version.
struct MainPanel: View {
    enum Style { case window, menuBar }
    let style: Style

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var extensionMonitor = ExtensionMonitor.shared
    @ObservedObject private var systemExtension = SystemExtensionInstaller.shared
    @State private var showScan = false

    var body: some View {
        VStack(alignment: .leading, spacing: style == .window ? 18 : 12) {
            notices
            if model.profiles.isEmpty {
                welcome
            } else {
                if style == .window {
                    header
                    connectButton
                } else {
                    compactHeader
                }
                connectionSection
                if model.routingMode.requiresSelectedApps {
                    appsSection
                }
                if model.routingMode.includesBrowser {
                    websitesSection
                }
            }
            if style == .menuBar {
                menuBarFooter
            }
        }
        .padding(style == .window ? 20 : 14)
        .sheet(isPresented: $showScan) {
            ProfileScanSheet { urls in model.importProfiles(urls) }
        }
    }

    private var locked: Bool { model.configurationLocked }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        SystemExtensionBanner(installer: systemExtension)
        if extensionMonitor.browserRoutingBroken || model.routingRepairPhase.isBusy {
            RoutingRepairBanner(
                blocksListedSites: extensionMonitor.blocksListedSites,
                phase: model.routingRepairPhase,
                onRepair: model.repairVPNRouting
            )
        }
        ExtensionUpdateBanner(monitor: extensionMonitor) {
            SettingsWindowController.shared.show(.browser)
        }
    }

    // MARK: - Connection

    private var orbState: OrbState {
        switch model.displayedStatus {
        case .connected: return .connected
        case .connecting, .reasserting, .disconnecting: return .changing
        default: return .off
        }
    }

    private var subtitle: String {
        guard let profile = model.selectedProfile else { return "Choose a profile" }
        let meta = model.profileMeta(profile)
        return "\(meta.displayName) · \(meta.host)"
    }

    private var header: some View {
        VStack(spacing: 10) {
            StatusOrb(state: orbState)
            VStack(spacing: 3) {
                Text(model.statusTitle)
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            StatusOrb(state: orbState, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Toggle("Connected", isOn: Binding(
                get: { model.isTunnelActive },
                set: { $0 ? model.connect() : model.disconnect() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(model.selectedProfile == nil || model.displayedStatus == .disconnecting)
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        let status = model.displayedStatus
        if status == .connected || status == .reasserting {
            Button(action: model.disconnect) {
                Text("Disconnect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else if status == .connecting {
            Button(action: model.disconnect) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Cancel")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else if status == .disconnecting {
            Button {} label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Disconnecting…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(true)
        } else {
            Button { model.connect() } label: {
                Text("Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(SemiTheme.brand)
            .controlSize(.large)
            .disabled(model.selectedProfile == nil)
        }
    }

    private var connectionSection: some View {
        SectionBox(footer: model.isTunnelActive && style == .window
                   ? "Disconnect to change the profile or route."
                   : (style == .window ? model.routingMode.choiceDetail : nil)) {
            SectionRow(first: true) {
                Text("Profile")
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 12)
                profileMenu
            }
            SectionRow {
                Text("Use VPN for")
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 12)
                Picker("Use VPN for", selection: Binding(
                    get: { model.routingMode },
                    set: { model.setRoutingMode($0) }
                )) {
                    ForEach(SharedConfig.RoutingMode.allCases) { mode in
                        Text(mode.choiceTitle).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize(horizontal: style == .window, vertical: false)
                .disabled(locked)
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            ForEach(model.profiles, id: \.self) { name in
                let meta = model.profileMeta(name)
                Toggle(isOn: Binding(
                    get: { name == model.selectedProfile },
                    set: { if $0 { model.chooseProfile(name) } }
                )) {
                    Text("\(meta.displayName) — \(meta.host)")
                }
            }
            Divider()
            Button("Import Profile…") {
                AppDelegate.shared?.showWindow()
                model.showProfilePicker()
            }
            Button("Manage Profiles…") {
                SettingsWindowController.shared.show(.profiles)
            }
        } label: {
            Text(model.selectedProfile.map { model.profileMeta($0).displayName } ?? "None")
        }
        .fixedSize()
        .disabled(locked)
    }

    // MARK: - Apps

    private var appsSection: some View {
        let apps = model.sortedApps
        return SectionBox(title: "Apps", footer: locked && style == .window ? "Disconnect to change the apps." : nil) {
            if apps.isEmpty {
                SectionRow(first: true) {
                    Text(style == .window ? "Add the apps that should use the VPN." : "No apps added yet.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                ItemRow(first: index == 0, removable: style == .window && !locked,
                        onRemove: { model.removeApp(app) }) {
                    Image(nsImage: model.appIcon(app))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(app.name)
                        .lineLimit(1)
                } trailing: {
                    Toggle(app.name, isOn: Binding(
                        get: { model.isAppEnabled(app) },
                        set: { model.setApp(app, enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(locked)
                }
            }
            if style == .window {
                SectionRow {
                    Button {
                        model.showAppPicker()
                    } label: {
                        Label("Add Apps…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(locked)
                }
            }
        }
    }

    // MARK: - Websites

    private var websitesSection: some View {
        SectionBox(title: "Websites") {
            if model.domains.isEmpty {
                SectionRow(first: true) {
                    Text(style == .window
                         ? "Add the websites that should use the VPN, here or from the browser extension."
                         : "No websites added yet.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(model.domains.enumerated()), id: \.element) { index, domain in
                ItemRow(first: index == 0, removable: style == .window,
                        onRemove: { model.removeDomain(domain) }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(domain)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.subdomainDomains.contains(domain) ? "and its subdomains" : "and www")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } trailing: {
                    Toggle(domain, isOn: Binding(
                        get: { model.isDomainEnabled(domain) },
                        set: { model.setDomainEnabled(domain, enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(model.isDomainEnabled(domain) ? "Pause \(domain)" : "Resume \(domain)")
                }
            }
            if style == .window {
                AddWebsiteRow()
                extensionRow
            }
        }
    }

    /// The browser extension's state, with a way to set it up.
    private var extensionRow: some View {
        SectionRow {
            let active = extensionMonitor.profiles.contains(where: \.isActive)
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(active ? SemiTheme.green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Browser extension")
                Text(extensionSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(extensionMonitor.profiles.isEmpty ? "Set Up…" : "Details…") {
                SettingsWindowController.shared.show(.browser)
            }
            .controlSize(.small)
        }
    }

    private var extensionSummary: String {
        if let active = extensionMonitor.profiles.first(where: \.isActive) {
            let others = extensionMonitor.profiles.filter(\.isActive).count - 1
            return "Active in \(active.label)" + (others > 0 ? " and \(others) more" : "")
        }
        if !extensionMonitor.profiles.isEmpty { return "Waiting for the browser to open" }
        return "Needed to route websites"
    }

    // MARK: - No profile yet

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: style == .window ? 96 : 56, height: style == .window ? 96 : 56)
            VStack(spacing: 4) {
                Text("Welcome to SemiVPN")
                    .font(.system(size: style == .window ? 20 : 15, weight: .semibold))
                Text("Import an OpenVPN profile (.ovpn) to get started.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if style == .window {
                Button {
                    model.showProfilePicker()
                } label: {
                    Text("Import Profile…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SemiTheme.brand)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button("Find Profiles on This Mac…") {
                    showScan = true
                }
                .buttonStyle(.link)
            } else {
                Button("Open SemiVPN") {
                    MenuBarController.shared?.close()
                    AppDelegate.shared?.showWindow()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, style == .window ? 40 : 8)
    }

    // MARK: - Menu bar

    private var menuBarFooter: some View {
        HStack(spacing: 4) {
            Button("Open SemiVPN") {
                MenuBarController.shared?.close()
                AppDelegate.shared?.showWindow()
            }
            Spacer()
            Button {
                MenuBarController.shared?.close()
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit SemiVPN")
        }
        .buttonStyle(.borderless)
        .padding(.top, 2)
    }
}

/// A row with something on the left, a control on the right, and a remove
/// button that appears while the pointer is over it.
private struct ItemRow<Leading: View, Trailing: View>: View {
    let first: Bool
    let removable: Bool
    let onRemove: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        SectionRow(first: first, verticalPadding: 6) {
            leading
            Spacer(minLength: 8)
            if removable && hovering {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
            trailing
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if removable {
                Button("Remove", action: onRemove)
            }
        }
    }
}

/// Adds a website: the address, and whether its subdomains are included.
private struct AddWebsiteRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var includeSubdomains = true
    @State private var error: String?

    var body: some View {
        SectionRow {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Add a website, like example.com", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                        .onChange(of: text) { _, _ in error = nil }
                    Button("Add", action: add)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Toggle("Include subdomains", isOn: $includeSubdomains)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func add() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let message = model.addDomain(text, includeSubdomains: includeSubdomains) {
            error = message
        } else {
            text = ""
        }
    }
}

/// The main window.
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            MainPanel(style: .window)
        }
        .frame(width: 400)
        .frame(minHeight: 480, idealHeight: 660)
        .background(SemiTheme.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(item: Binding(
            get: { model.vpn.credentialRequest },
            set: { model.vpn.credentialRequest = $0 }
        )) { request in
            CredentialPrompt(request: request, purpose: .connect) { credentials, remember in
                model.vpn.credentialRequest = nil
                model.connect(credentials: credentials, remember: remember)
            } onCancel: {
                model.vpn.credentialRequest = nil
            }
        }
        .alert("SemiVPN Couldn’t Connect", isPresented: Binding(
            get: { model.connectError != nil },
            set: { if !$0 { model.connectError = nil } }
        )) {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.connectError ?? "", forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.connectError ?? "")
        }
    }
}

/// The menu bar panel: the main panel, sized to its content up to a limit.
struct MenuBarPanel: View {
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            MainPanel(style: .menuBar)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
        }
        .frame(width: 340, height: min(contentHeight, 600))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }

    private struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
}
