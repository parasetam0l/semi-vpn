import AppKit
import SwiftUI

// MARK: - Window

/// The main window: the connection on a color that shows its state, from
/// the top of the window; the list of apps or websites in a sheet below,
/// which scrolls however long it gets.
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.profiles.isEmpty {
                VStack(spacing: 14) {
                    NoticesView()
                    WelcomeView(compact: false)
                        .frame(maxHeight: .infinity)
                }
                .padding(16)
            } else {
                VStack(spacing: 0) {
                    ConnectionHero()
                        // Room for the color behind the sheet's corners.
                        .padding(.bottom, ListSheet.overlap + 18)
                        .background(HeroBackground(state: model.orbState).ignoresSafeArea(edges: .top))
                    ListSheet()
                        .padding(.top, -ListSheet.overlap)
                }
            }
        }
        .frame(width: 400)
        .frame(minHeight: 600, idealHeight: 720, maxHeight: .infinity, alignment: .top)
        .background(SemiTheme.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IPAddressButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        // After the toolbar items: its spacer must come before them.
        .modifier(PlainTitleBar())
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

/// One surface from the top of the window: no title text (the status
/// header names the window; Mission Control and the Window menu still say
/// SemiVPN) and no separate title bar background. Without the title, the
/// toolbar buttons would follow the traffic lights: a flexible spacer keeps
/// them on the right. macOS 26 and later (ToolbarSpacer).
private struct PlainTitleBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar { ToolbarSpacer(.flexible) }
        } else {
            content
        }
    }
}

/// The power button, the state and how long it has lasted, and the profile
/// and route as menus, in white on HeroBackground.
private struct ConnectionHero: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            PowerButton()
            VStack(spacing: 3) {
                Text(model.statusTitle)
                    .font(.system(size: 24, weight: .bold))
                subtitle
                    .font(.system(size: 12).monospacedDigit())
                    .opacity(0.85)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white)
            HStack(spacing: 8) {
                ProfileChip()
                RouteChip()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    /// While connected: the server and the time connected, ticking.
    /// Otherwise the profile and its server.
    @ViewBuilder
    private var subtitle: some View {
        let profile = model.connectedProfile ?? model.selectedProfile
        let meta = profile.map(model.profileMeta)
        if let since = model.vpn.connectedDate, let meta {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                Text("\(meta.host) · \(Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond)))")
            }
        } else if let meta {
            Text("\(meta.displayName) · \(meta.host)")
        } else {
            Text("Choose a profile")
        }
    }
}

/// Connects, cancels a connection attempt, or disconnects.
private struct PowerButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let status = model.displayedStatus
        let busy = status == .connecting || status == .disconnecting || model.vpn.isReconnecting
        Button(action: toggle) {
            ZStack {
                Circle().fill(.white.opacity(0.12)).frame(width: 112, height: 112)
                Circle().fill(.white.opacity(0.2)).frame(width: 90, height: 90)
                Circle().fill(.white).frame(width: 68, height: 68)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                if busy {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(model.isConnected ? SemiTheme.brand : Color(white: 0.45))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(model.selectedProfile == nil || status == .disconnecting)
        .help(help)
        .accessibilityLabel(help)
    }

    private var help: String {
        switch model.displayedStatus {
        case .connected, .reasserting: return "Disconnect"
        case .connecting: return "Cancel connecting"
        case .disconnecting: return "Disconnecting…"
        default: return "Connect"
        }
    }

    private func toggle() {
        switch model.displayedStatus {
        case .connected, .reasserting, .connecting: model.disconnect()
        default: model.connect()
        }
    }
}

/// A button that shrinks a little while pressed.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The color behind the connection: the brand gradient while connected,
/// gray when not, in between while it changes.
private struct HeroBackground: View {
    let state: OrbState

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.55), Color(white: 0.38)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            SemiTheme.gradient
                .opacity(state == .connected ? 1 : state == .changing ? 0.55 : 0)
        }
        .animation(.easeInOut(duration: 0.4), value: state)
    }
}

/// A white capsule menu on the hero: icon, value, chevron.
private struct HeroChip: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .opacity(0.85)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .opacity(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.white.opacity(0.18)))
        .contentShape(Capsule())
    }
}

private struct ProfileChip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            ProfileMenuItems()
        } label: {
            HeroChip(icon: "person.crop.circle",
                     title: model.selectedProfile.map { model.profileMeta($0).displayName } ?? "Choose a Profile")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profile")
    }
}

private struct RouteChip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            RouteOptions()
                .pickerStyle(.inline)
        } label: {
            HeroChip(icon: "arrow.triangle.branch", title: model.routingMode.choiceTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.routingMode.choiceDetail)
    }
}

/// The notices, a pending reconnect, and the list of apps or websites, on
/// a sheet whose top corners round over the hero's color.
private struct ListSheet: View {
    static let overlap: CGFloat = 22
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoticesView()
            PendingChangesNotice()
            if model.shownListKind == nil {
                AllTrafficNote()
            } else {
                RoutedList()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                .fill(SemiTheme.canvas)
                .shadow(color: .black.opacity(0.2), radius: 10, y: -2)
        )
    }
}

// MARK: - Menu bar

/// The menu bar panel: the connection and its choices, how many apps and
/// websites use the VPN (the lists themselves are in the window), and the
/// IP addresses, checked each time the panel opens.
struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoticesView()
            if model.profiles.isEmpty {
                WelcomeView(compact: true)
            } else {
                ConnectionHeader()
                ConnectionChoices()
                PendingChangesNotice()
                if !model.listKinds.isEmpty {
                    SectionBox {
                        ForEach(Array(model.listKinds.enumerated()), id: \.element) { index, kind in
                            summaryRow(kind, first: index == 0)
                        }
                    }
                }
                IPAddressSummary(checker: IPAddressChecker.shared)
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

/// The menu bar panel's status, the profile in use and its switch.
struct ConnectionHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            StatusOrb(state: model.orbState, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

    private var subtitle: String {
        guard let profile = model.connectedProfile ?? model.selectedProfile else { return "Choose a profile" }
        let meta = model.profileMeta(profile)
        return "\(meta.displayName) · \(meta.host)"
    }
}

/// The menu bar panel's profile and route.
struct ConnectionChoices: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionBox {
            SectionRow(first: true) {
                Text("Profile")
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 12)
                Menu {
                    ProfileMenuItems()
                } label: {
                    Text(model.selectedProfile.map { model.profileMeta($0).displayName } ?? "None")
                }
                .fixedSize()
            }
            SectionRow {
                Text("Use VPN for")
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 12)
                RouteOptions()
                    .labelsHidden()
                    .pickerStyle(.menu)
            }
        }
    }
}

/// The profiles to choose from, Import Profile… and Manage Profiles….
struct ProfileMenuItems: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
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
    }
}

/// What uses the VPN, as a picker.
struct RouteOptions: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Picker("Use VPN for", selection: Binding(
            get: { model.routingMode },
            set: { model.setRoutingMode($0) }
        )) {
            ForEach(SharedConfig.RoutingMode.allCases) { mode in
                Text(mode.choiceTitle).tag(mode)
            }
        }
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
            Text("To choose apps or websites instead, change “All Apps” above.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lists

/// The apps or websites that use the VPN: a switcher when the mode uses
/// both, a field that searches the list (and adds a website) beside Add
/// Apps… or the browser extension's state, the list, and a footer with
/// counts and actions on all of them.
private struct RoutedList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var extensionMonitor = ExtensionMonitor.shared
    @State private var selection: Set<String> = []
    @State private var addError: String?

    private var kind: AppModel.ListKind { model.shownListKind ?? .websites }
    private var query: String { model.listSearch }

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
                    model.showAppPicker()
                } label: {
                    Label("Add Apps…", systemImage: "plus")
                }
            } else {
                ExtensionStatusButton(monitor: extensionMonitor)
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
                    AppListRow(app: app) { request(remove: [app.bundleIdentifier]) }
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
                Button("Turn Off") { setEnabled(items, false) }
                Divider()
                Button(items.count == 1 ? "Remove…" : "Remove \(items.count)…", role: .destructive) {
                    request(remove: items)
                }
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
                Button("Turn All Off") { setEnabled(allIdentifiers, false) }
                Divider()
                if kind == .apps {
                    Button("Import Apps…", action: model.importApps)
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
        return counts + selected
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
        guard !items.isEmpty else { return }
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
    let onRemove: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: model.appIcon(app))
                .resizable()
                .frame(width: 18, height: 18)
            Text(app.name)
                .lineLimit(1)
            Spacer(minLength: 6)
            if hovering {
                RemoveButton(action: onRemove)
            }
            Toggle(app.name, isOn: Binding(
                get: { model.isAppEnabled(app) },
                set: { model.setApp(app, enabled: $0) }
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

/// Changes made while connected (profile, route, apps) and the button
/// that applies them: macOS uses them only when the tunnel starts again.
private struct PendingChangesNotice: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let changes = model.pendingChanges
        if !changes.isEmpty {
            NoticeCard(
                icon: "arrow.triangle.2.circlepath",
                tint: SemiTheme.brand,
                title: "Reconnect to use the new \(Self.describe(changes))",
                detail: "Apps that use the VPN lose their connection for a few seconds."
            ) {
                Button("Reconnect", action: model.reconnect)
                    .buttonStyle(.borderedProminent)
                    .tint(SemiTheme.brand)
            }
        }
    }

    private static func describe(_ changes: [String]) -> String {
        let names = changes.map { $0 == "apps" ? "app list" : $0 }
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
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
