import AppKit
import SwiftUI

// MARK: - Window

/// The main window: the connection and its choices stay in place at the
/// top; the list of apps or websites below scrolls, however long it gets.
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NoticesView()
            if model.profiles.isEmpty {
                WelcomeView(compact: false)
                    .frame(maxHeight: .infinity)
            } else {
                ConnectionHeader(style: .window)
                ConnectionChoices(style: .window)
                if model.shownListKind == nil {
                    AllTrafficNote()
                } else {
                    RoutedList()
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .frame(minHeight: 520, idealHeight: 700, maxHeight: .infinity, alignment: .top)
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

// MARK: - Menu bar

/// The menu bar panel: the connection and its choices, and how many apps
/// and websites use the VPN; the lists themselves are in the window.
struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoticesView()
            if model.profiles.isEmpty {
                WelcomeView(compact: true)
            } else {
                ConnectionHeader(style: .menuBar)
                ConnectionChoices(style: .menuBar)
                if !model.listKinds.isEmpty {
                    SectionBox {
                        ForEach(Array(model.listKinds.enumerated()), id: \.element) { index, kind in
                            summaryRow(kind, first: index == 0)
                        }
                    }
                }
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryRow(_ kind: AppModel.ListKind, first: Bool) -> some View {
        Button {
            model.listKind = kind
            MenuBarController.shared?.close()
            AppDelegate.shared?.showWindow()
        } label: {
            SectionRow(first: first) {
                Image(systemName: kind == .apps ? "square.grid.2x2" : "globe")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(kind == .apps ? "Apps" : "Websites")
                Spacer()
                Text(kind == .apps
                     ? "\(model.enabledAppCount) of \(model.addedApps.count) on"
                     : "\(model.enabledDomainCount) of \(model.domains.count) on")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind == .apps ? "Show the apps in SemiVPN" : "Show the websites in SemiVPN")
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button("Open SemiVPN") {
                MenuBarController.shared?.close()
                AppDelegate.shared?.showWindow()
            }
            Spacer()
            HStack(spacing: 16) {
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
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Connection

/// The window and the menu bar panel differ only in their controls.
enum PanelStyle {
    case window, menuBar
}

/// Warnings that need the user: the network extension's approval, browser
/// traffic outside the VPN, an outdated browser extension.
struct NoticesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var extensionMonitor = ExtensionMonitor.shared
    @ObservedObject private var systemExtension = SystemExtensionInstaller.shared

    var body: some View {
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
}

/// The status, the profile in use and the way to connect or disconnect.
struct ConnectionHeader: View {
    let style: PanelStyle
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            StatusOrb(state: orbState, size: style == .window ? 46 : 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusTitle)
                    .font(.system(size: style == .window ? 16 : 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if style == .window {
                connectButton
            } else {
                Toggle("Connected", isOn: Binding(
                    get: { model.isTunnelActive },
                    set: { $0 ? model.connect() : model.disconnect() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.selectedProfile == nil || model.displayedStatus == .disconnecting)
            }
        }
    }

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

    @ViewBuilder
    private var connectButton: some View {
        switch model.displayedStatus {
        case .connected, .reasserting:
            Button("Disconnect", role: .destructive, action: model.disconnect)
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
        case .connecting:
            Button(action: model.disconnect) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Cancel")
                }
            }
            .controlSize(.large)
        case .disconnecting:
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Disconnecting…")
                }
            }
            .controlSize(.large)
            .disabled(true)
        default:
            Button { model.connect() } label: {
                Text("Connect").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(SemiTheme.brand)
            .controlSize(.large)
            .disabled(model.selectedProfile == nil)
        }
    }
}

/// The profile and what uses the VPN.
struct ConnectionChoices: View {
    let style: PanelStyle
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionBox(footer: style == .window
                   ? (model.isTunnelActive ? "Disconnect to change the profile or route." : model.routingMode.choiceDetail)
                   : nil) {
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
                .disabled(model.configurationLocked)
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
                MenuBarController.shared?.close()
                AppDelegate.shared?.showWindow()
                model.showProfilePicker()
            }
            Button("Manage Profiles…") {
                MenuBarController.shared?.close()
                SettingsWindowController.shared.show(.profiles)
            }
        } label: {
            Text(model.selectedProfile.map { model.profileMeta($0).displayName } ?? "None")
        }
        .fixedSize()
        .disabled(model.configurationLocked)
    }
}

/// Shown instead of a list in All Apps mode.
private struct AllTrafficNote: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("All traffic from this Mac uses the VPN.")
                .font(.system(size: 13, weight: .medium))
            Text("To choose apps or websites instead, change “Use VPN for”.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lists

/// The apps or websites that use the VPN: a switcher when the mode uses
/// both, a field that searches the list (and adds a website), the list,
/// and a footer with counts and actions on all of them.
private struct RoutedList: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Set<String> = []
    @State private var addError: String?
    @State private var showLockedHint = false

    private var kind: AppModel.ListKind { model.shownListKind ?? .websites }
    private var query: String { model.listSearch }
    private var locked: Bool { kind == .apps && model.configurationLocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.listKinds.count > 1 {
                Picker("List", selection: $model.listKind) {
                    Text("Apps \(model.addedApps.count)").tag(AppModel.ListKind.apps)
                    Text("Websites \(model.domains.count)").tag(AppModel.ListKind.websites)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            searchField
            if let candidate = addCandidate {
                addRow(candidate)
            }
            if let addError {
                Text(addError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            list
            footer
        }
        .onChange(of: model.listKind) { _, _ in
            selection = []
            model.listSearch = ""
            addError = nil
        }
    }

    // MARK: Search and add

    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(kind == .apps ? "Search apps" : "Search or add a website", text: $model.listSearch)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                    .onChange(of: model.listSearch) { _, _ in addError = nil }
                if !query.isEmpty {
                    Button {
                        model.listSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SemiTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SemiTheme.line, lineWidth: 0.5))
            if kind == .apps {
                Button {
                    if locked {
                        showLockedHint = true
                    } else {
                        model.showAppPicker()
                    }
                } label: {
                    Label("Add Apps…", systemImage: "plus")
                }
                .popover(isPresented: $showLockedHint, arrowEdge: .bottom) {
                    LockedAppsHint {
                        showLockedHint = false
                        model.disconnect()
                    }
                }
            }
        }
    }

    /// A website the search text names that isn't in the list yet.
    private var addCandidate: String? {
        guard kind == .websites, query.contains("."),
              let domain = SharedConfig.routingDomain(query),
              !model.domains.contains(domain) else { return nil }
        return domain
    }

    private func addRow(_ domain: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(SemiTheme.brand)
                Text("Add \(domain)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Only This Site") { add(domain, includeSubdomains: false) }
                    .help("\(domain) and www.\(domain)")
                Button("With Subdomains") { add(domain, includeSubdomains: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(SemiTheme.brand)
                    .help("\(domain) and every *.\(domain) (Return)")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SemiTheme.brand.opacity(0.10)))
    }

    private func submit() {
        if let candidate = addCandidate {
            add(candidate, includeSubdomains: true)
        }
    }

    private func add(_ domain: String, includeSubdomains: Bool) {
        if let message = model.addDomain(domain, includeSubdomains: includeSubdomains) {
            addError = message
        } else {
            model.listSearch = ""
            selection = [domain]
        }
    }

    // MARK: List

    private var filteredApps: [AppEntry] {
        let apps = model.sortedApps
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.bundleIdentifier.localizedCaseInsensitiveContains(text) }
    }

    private var filteredDomains: [String] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return model.domains }
        let needle = SharedConfig.routingDomain(text) ?? text
        return model.domains.filter { $0.contains(needle) || $0.contains(text) }
    }

    private var list: some View {
        List(selection: $selection) {
            if kind == .apps {
                ForEach(filteredApps) { app in
                    AppListRow(app: app, locked: locked) { request(remove: [app.bundleIdentifier]) }
                        .tag(app.bundleIdentifier)
                }
            } else {
                ForEach(filteredDomains, id: \.self) { domain in
                    WebsiteListRow(domain: domain) { request(remove: [domain]) }
                        .tag(domain)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(SemiTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SemiTheme.line, lineWidth: 0.5))
        .overlay { emptyState }
        .frame(minHeight: 160, maxHeight: .infinity)
        .contextMenu(forSelectionType: String.self) { items in
            if !items.isEmpty {
                Button("Turn On") { setEnabled(items, true) }
                    .disabled(locked)
                Button("Turn Off") { setEnabled(items, false) }
                    .disabled(locked)
                Divider()
                Button(items.count == 1 ? "Remove…" : "Remove \(items.count)…", role: .destructive) {
                    request(remove: items)
                }
                .disabled(locked)
            }
        }
        .onDeleteCommand {
            request(remove: selection)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let isEmpty = kind == .apps ? model.addedApps.isEmpty : model.domains.isEmpty
        let noMatches = kind == .apps ? filteredApps.isEmpty : filteredDomains.isEmpty
        if isEmpty {
            VStack(spacing: 6) {
                Text(kind == .apps ? "No apps yet" : "No websites yet")
                    .font(.system(size: 13, weight: .medium))
                Text(kind == .apps
                     ? "Add the apps that should use the VPN, or import a list."
                     : "Type a website above, add one from the browser extension, or import a list.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        } else if noMatches && addCandidate == nil {
            Text("No matches for “\(query)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.75))
            Spacer()
            Menu {
                Button("Turn All On") { setEnabled(allIdentifiers, true) }
                    .disabled(locked)
                Button("Turn All Off") { setEnabled(allIdentifiers, false) }
                    .disabled(locked)
                Divider()
                if kind == .apps {
                    Button("Import Apps…", action: model.importApps)
                        .disabled(locked)
                    Button("Export Apps…", action: model.exportApps)
                        .disabled(model.addedApps.isEmpty)
                } else {
                    Button("Import Websites…", action: model.importWebsites)
                    Button("Export Websites…", action: model.exportWebsites)
                        .disabled(model.domains.isEmpty)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    private var summary: String {
        guard !allIdentifiers.isEmpty else { return "" }
        let counts = kind == .apps
            ? "\(model.enabledAppCount) of \(model.addedApps.count) on"
            : "\(model.enabledDomainCount) of \(model.domains.count) on"
        let selected = selection.count > 1 ? " · \(selection.count) selected" : ""
        let lockedNote = locked ? " · disconnect to change" : ""
        return counts + selected + lockedNote
    }

    private var allIdentifiers: Set<String> {
        kind == .apps ? Set(model.addedApps.keys) : Set(model.domains)
    }

    private func setEnabled(_ items: Set<String>, _ enabled: Bool) {
        if kind == .apps {
            model.setApps(items, enabled: enabled)
        } else {
            model.setDomainsEnabled(items, enabled: enabled)
        }
    }

    private func request(remove items: Set<String>) {
        guard !items.isEmpty, !locked else { return }
        let kind = kind
        model.confirmRemoval(kind, items) {
            if kind == .apps {
                model.removeApps(items)
            } else {
                model.removeDomains(items)
            }
            selection.subtract(items)
        }
    }
}

/// One app: icon, name, and its switch.
private struct AppListRow: View {
    let app: AppEntry
    let locked: Bool
    let onRemove: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false
    @State private var showLockedHint = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: model.appIcon(app))
                .resizable()
                .frame(width: 18, height: 18)
            Text(app.name)
                .lineLimit(1)
            Spacer(minLength: 6)
            if hovering && !locked {
                RemoveButton(action: onRemove)
            }
            // While connected the switch stays clickable, explains why it
            // doesn't change, and stays as it was.
            Toggle(app.name, isOn: Binding(
                get: { model.isAppEnabled(app) },
                set: { enabled in
                    if locked {
                        showLockedHint = true
                    } else {
                        model.setApp(app, enabled: enabled)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .popover(isPresented: $showLockedHint, arrowEdge: .trailing) {
                LockedAppsHint(title: "Disconnect to change apps") {
                    showLockedHint = false
                    model.disconnect()
                }
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// One website: the domain, whether subdomains are included, its switch.
private struct WebsiteListRow: View {
    let domain: String
    let onRemove: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(domain)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.subdomainDomains.contains(domain) {
                Text("+ subdomains")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            if hovering {
                RemoveButton(action: onRemove)
            }
            Toggle(domain, isOn: Binding(
                get: { model.isDomainEnabled(domain) },
                set: { model.setDomainEnabled(domain, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Shown by Add Apps… and the app switches while connected: the app rules
/// are fixed until the VPN disconnects.
private struct LockedAppsHint: View {
    var title = "Disconnect to add apps"
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text("Apps can’t be added or changed while the VPN is connected.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

private struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove…")
    }
}

// MARK: - No profile yet

struct WelcomeView: View {
    let compact: Bool
    @EnvironmentObject private var model: AppModel
    @State private var showScan = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: compact ? 56 : 96, height: compact ? 56 : 96)
            VStack(spacing: 4) {
                Text("Welcome to SemiVPN")
                    .font(.system(size: compact ? 15 : 20, weight: .semibold))
                Text("Import an OpenVPN profile (.ovpn) to get started.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if compact {
                Button("Open SemiVPN") {
                    MenuBarController.shared?.close()
                    AppDelegate.shared?.showWindow()
                }
            } else {
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
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 8 : 40)
        .sheet(isPresented: $showScan) {
            ProfileScanSheet { urls in model.importProfiles(urls) }
        }
    }
}
