import SwiftUI
import AppKit
import NetworkExtension
import OpenVPNCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var vpnManager: VPNManager
    @State private var profiles: [String] = []
    @State private var selectedProfile: String?
    @State private var selectedApps: Set<String> = []
    @State private var addedApps: [String: AppEntry] = [:]
    @State private var routingMode: SharedConfig.RoutingMode = .allApps
    @State private var domains: [String] = []
    @State private var subdomainDomains: Set<String> = []
    @State private var inactiveDomains: Set<String> = []
    @State private var domainInput = ""
    @State private var domainInputError: String?
    @State private var pendingDomainToAdd: String?
    @State private var showDomainSubdomainPrompt = false
    @State private var discoveredProfiles: [URL] = []
    @State private var showScanDialog = false
    @State private var scanDesktop = true
    @State private var scanDocuments = true
    @State private var scanDownloads = true
    @State private var scanOpenVPN = false
    @State private var scanning = false
    @State private var showScanResults = false
    @State private var selectedScanProfiles: Set<URL> = []
    @State private var importError: String?
    @State private var connecting = false
    @State private var errorMessage: String?
    @State private var showImportError = false
    @State private var showConnectError = false
    @State private var showSettings = false
    @State private var showProfileMenu = false
    @State private var extensiveLogging = AppLogger.enabled
    @State private var launchAtLogin = true
    @State private var launchAtLoginError: String?
    @State private var chromeExtensionReady = false
    @State private var chromeExtensionError: String?
    @State private var chromeExtensionDirectory: URL?
    @State private var tunnelRegistered = false
    @State private var perAppConfigSaved = false
    @State private var vpnConfigSaved = false
    @State private var workspaceSection: WorkspaceSection = .overview

    private var fullTunnel: Bool { routingMode.usesFullTunnel }
    private var domainRouting: Bool { routingMode.includesBrowser }

    var body: some View {
        HStack(spacing: 0) {
            workspaceSidebar
            Rectangle()
                .fill(SemiTheme.line)
                .frame(width: 1)
            VStack(spacing: 0) {
                workspaceTopBar
                Rectangle()
                    .fill(SemiTheme.line)
                    .frame(height: 1)
                sectionContent
                if workspaceSection != .overview {
                    Rectangle()
                        .fill(SemiTheme.line)
                        .frame(height: 1)
                    connectionFooter
                }
            }
        }
        .frame(minWidth: 960, idealWidth: 1020, minHeight: 650, idealHeight: 720)
        .background(SemiTheme.canvas)
        .preferredColorScheme(.dark)
        .onAppear {
            refresh()
            AppLogger.log("app launched")
        }
        .onChange(of: routingMode) { _, _ in
            guard !configurationLocked else { return }
            saveCurrentSelection()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: SharedConfig.domainConfigurationDidChangeNotification
        )) { _ in
            refreshDomains()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: SharedConfig.selectionDidChangeNotification
        )) { _ in
            refresh()
        }
        .sheet(isPresented: $showScanDialog) {
            scanDialog
        }
        .sheet(isPresented: $showImportError) {
            ErrorDialog(title: "Import Error", message: importError ?? "") {
                showImportError = false
            }
        }
        .sheet(isPresented: $showConnectError) {
            ErrorDialog(title: "Connection Error", message: errorMessage ?? "") {
                showConnectError = false
            }
        }
        .alert("Add domain", isPresented: $showDomainSubdomainPrompt) {
            Button("Add subdomains") {
                let domain = pendingDomainToAdd
                pendingDomainToAdd = nil
                if let domain { commitDomain(domain, includeSubdomains: true) }
            }
            Button("Only domain + www") {
                let domain = pendingDomainToAdd
                pendingDomainToAdd = nil
                if let domain { commitDomain(domain, includeSubdomains: false) }
            }
            Button("Cancel", role: .cancel) {
                pendingDomainToAdd = nil
            }
        } message: {
            Text("Include all subdomains for \(pendingDomainToAdd ?? "this domain")? Exact-host routing also includes the domain's www variant.")
        }
    }

    // MARK: - New workspace presentation

    private enum WorkspaceSection: String, CaseIterable, Identifiable {
        case overview, routing, browser, profiles, diagnostics

        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .routing: return "Routing"
            case .browser: return "Browser"
            case .profiles: return "Profiles"
            case .diagnostics: return "Diagnostics"
            }
        }
        var subtitle: String {
            switch self {
            case .overview: return "Connection at a glance"
            case .routing: return "Choose which apps use the tunnel"
            case .browser: return "Route Chrome domains independently"
            case .profiles: return "Manage .ovpn configurations"
            case .diagnostics: return "System and extension health"
            }
        }
        var icon: String {
            switch self {
            case .overview: return "rectangle.grid.1x2.fill"
            case .routing: return "arrow.left.arrow.right"
            case .browser: return "globe.badge.chevron.backward"
            case .profiles: return "doc.on.doc"
            case .diagnostics: return "waveform.path.ecg"
            }
        }
    }

    private enum SemiTheme {
        static let canvas = Color(red: 0.025, green: 0.035, blue: 0.095)
        static let sidebar = Color(red: 0.045, green: 0.060, blue: 0.145)
        static let panel = Color(red: 0.065, green: 0.085, blue: 0.19)
        static let panelRaised = Color(red: 0.095, green: 0.125, blue: 0.255)
        static let line = Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.18)
        static let textMuted = Color.white.opacity(0.62)
        static let cyan = Color(red: 0.12, green: 0.82, blue: 1.0)
        static let violet = Color(red: 0.58, green: 0.28, blue: 1.0)
        static let green = Color(red: 0.28, green: 0.88, blue: 0.58)
        static let accent = LinearGradient(colors: [cyan, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private struct AccentButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SemiTheme.accent)
                        .opacity(configuration.isPressed ? 0.78 : 1.0)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.20), lineWidth: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
        }
    }

    private struct LargeAccentButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(configuration.isPressed ? 0.78 : 1.0))
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(SemiTheme.accent)
                        .opacity(configuration.isPressed ? 0.78 : 1.0)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
        }
    }

    private struct LargeDisconnectButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(configuration.isPressed ? 0.78 : 0.94))
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(SemiTheme.panelRaised.opacity(configuration.isPressed ? 0.65 : 0.92))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.red.opacity(0.72), lineWidth: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
        }
    }

    private struct SecondaryButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(configuration.isPressed ? 0.72 : 0.92))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SemiTheme.panelRaised.opacity(configuration.isPressed ? 0.65 : 0.92))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(SemiTheme.cyan.opacity(0.32), lineWidth: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
        }
    }

    private struct DisconnectButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(configuration.isPressed ? 0.72 : 0.94))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SemiTheme.panelRaised.opacity(configuration.isPressed ? 0.65 : 0.92))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.red.opacity(0.72), lineWidth: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
        }
    }

    private var workspaceSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandMark()
                    .frame(width: 39, height: 39)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SemiVPN")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Private routing control")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SemiTheme.textMuted)
                }
            }
            .padding(.top, 21)
            .padding(.bottom, 27)

            VStack(spacing: 4) {
                ForEach(WorkspaceSection.allCases) { item in
                    Button {
                        workspaceSection = item
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(item.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(SemiTheme.textMuted)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(workspaceSection == item ? SemiTheme.panelRaised : .clear)
                        }
                        .foregroundStyle(workspaceSection == item ? .white : SemiTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusInfo.1)
                        .frame(width: 8, height: 8)
                    Text(statusInfo.0)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                Text(sidebarSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(SemiTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 12).fill(SemiTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(SemiTheme.line))
            .padding(.bottom, 15)
        }
        .padding(.horizontal, 13)
        .frame(width: 238)
        .background(SemiTheme.sidebar)
    }

    private var workspaceTopBar: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(workspaceSection.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(workspaceSection.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(SemiTheme.textMuted)
            }
            Spacer()
            HStack(spacing: 9) {
                Circle()
                    .fill(statusInfo.1)
                    .frame(width: 8, height: 8)
                Text(statusInfo.0)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusInfo.1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(statusInfo.1.opacity(0.12)))
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 31, height: 31)
                    .background(Circle().fill(SemiTheme.panel))
            }
            .buttonStyle(.plain)
            .disabled(configurationLocked)
            .help("Settings and diagnostics")
        }
        .padding(.horizontal, 28)
        .padding(.top, 25)
        .padding(.bottom, 20)
        .background(WindowDragView())
        .sheet(isPresented: $showSettings) {
            settingsDialog
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch workspaceSection {
        case .overview: overviewWorkspace
        case .routing: routingWorkspace
        case .browser: browserWorkspace
        case .profiles: profilesWorkspace
        case .diagnostics: diagnosticsWorkspace
        }
    }

    private var overviewWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if profiles.isEmpty {
                    emptyWorkspace
                } else {
                    connectionHero
                    HStack(spacing: 12) {
                        metricTile("Profile", value: selectedProfile.map(profileEndpointLabel) ?? "None", icon: "doc.text.fill", tint: SemiTheme.violet) {
                            ForEach(profiles, id: \.self) { name in
                                Button {
                                    chooseProfile(name)
                                } label: {
                                    Label {
                                        Text(profileEndpointLabel(name))
                                    } icon: {
                                        Image(systemName: name == selectedProfile ? "checkmark" : "doc.text")
                                    }
                                }
                            }
                            Divider()
                            Button("Manage profiles…") {
                                workspaceSection = .profiles
                            }
                        }
                        .disabled(configurationLocked || profiles.isEmpty)
                        metricTile("App routing", value: routingMode.title, icon: "arrow.left.arrow.right", tint: SemiTheme.cyan) {
                            Button("Configure routing") {
                                workspaceSection = .routing
                            }
                        }
                        .disabled(configurationLocked)
                        metricTile("Browser", value: domainRouting ? "\(domains.count) domain\(domains.count == 1 ? "" : "s")" : "Off", icon: "globe", tint: SemiTheme.green) {
                            Button("Configure browser") {
                                workspaceSection = .browser
                            }
                        }
                    }
                    overviewConnectionControl
                }
            }
            .padding(28)
        }
        .onAppear { refreshDomains() }
    }

    private var connectionHero: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [SemiTheme.violet.opacity(0.38), SemiTheme.cyan.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: isTunnelActive ? "shield.checkered" : "shield")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(isTunnelActive ? "Tunnel is active" : "Ready to connect")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(connectionHeroDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(SemiTheme.textMuted)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(SemiTheme.line))
    }

    private var overviewConnectionControl: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(overviewConnectionIdentity)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(routingMode.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(SemiTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(overviewConnectionDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(SemiTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if isTunnelActive {
                Button(role: .destructive) {
                    vpnManager.stop()
                } label: {
                    Label("Disconnect", systemImage: "stop.fill")
                        .frame(minWidth: 190)
                }
                .buttonStyle(LargeDisconnectButtonStyle())
            } else if vpnManager.status == .disconnecting {
                Text("Disconnecting…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SemiTheme.textMuted)
            } else {
                Button {
                    connect()
                } label: {
                    Label(connecting ? "Connecting…" : "Connect", systemImage: "bolt.fill")
                        .frame(minWidth: 190)
                }
                .buttonStyle(LargeAccentButtonStyle())
                .disabled(selectedProfile == nil || connecting)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
    }

    private var chromeExtensionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            chromeExtensionSettings
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
    }

    private var changeProfileCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SemiTheme.violet)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 11).fill(SemiTheme.violet.opacity(0.14)))

            VStack(alignment: .leading, spacing: 4) {
                Text("CONNECTION PROFILE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(SemiTheme.textMuted)
                if let selectedProfile {
                    let meta = profileMeta(selectedProfile)
                    Text(meta.displayName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("\(meta.host)  ·  \(meta.protocolName)")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                        .lineLimit(1)
                } else {
                    Text("No profile selected")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Import an OpenVPN profile to get started.")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                }
            }

            Spacer()

            Menu {
                ForEach(profiles, id: \.self) { name in
                    Button {
                        chooseProfile(name)
                    } label: {
                        Label(profileMeta(name).displayName,
                              systemImage: name == selectedProfile ? "checkmark" : "doc.text")
                    }
                }
                Divider()
                Button("Manage profiles…") {
                    workspaceSection = .profiles
                }
            } label: {
                Label("Change profile", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(configurationLocked || profiles.isEmpty)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
    }

    private var selectedAppsPreview: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SemiTheme.cyan)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 11).fill(SemiTheme.cyan.opacity(0.14)))

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(routingMode.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(routingMode.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(SemiTheme.textMuted)
                    }
                    Spacer()
                    Button("Configure routing") { workspaceSection = .routing }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.small)
                        .disabled(configurationLocked)
                }
                if routingMode.requiresSelectedApps && !addedApps.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(addedApps.values.sorted(by: { $0.name < $1.name }).prefix(5)) { app in
                            HStack(spacing: 6) {
                                Image(nsImage: appIcon(for: app))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                Text(app.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SemiTheme.panelRaised))
                        }
                        if addedApps.count > 5 {
                            Text("+\(addedApps.count - 5) more")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SemiTheme.textMuted)
                        }
                    }
                } else if routingMode.requiresSelectedApps {
                    Text("No applications added yet. Add one to create a selected-app rule.")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
    }

    private var browserDomainsOverview: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SemiTheme.green)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 11).fill(SemiTheme.green.opacity(0.14)))

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Browser domain routing")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(domainRouting
                             ? "Chrome's listed domains use the VPN through SemiVPN's local proxy."
                             : "Domain rules are saved here and used only by a browser-enabled routing mode.")
                            .font(.system(size: 11))
                            .foregroundStyle(SemiTheme.textMuted)
                    }
                    Spacer()
                    Button("Configure browser") { workspaceSection = .browser }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.small)
                }
                if domains.isEmpty {
                    Text("No browser domains configured.")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                } else {
                    HStack(spacing: 8) {
                        ForEach(domains.prefix(5), id: \.self) { domain in
                            Text(domain)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SemiTheme.panelRaised))
                        }
                        if domains.count > 5 {
                            Text("+\(domains.count - 5) more")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SemiTheme.textMuted)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
    }

    private var routingWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workspaceIntro(icon: "arrow.left.arrow.right", title: "Routing mode", detail: "Choose exactly which application and browser traffic uses the connected VPN.")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(SharedConfig.RoutingMode.allCases) { mode in
                        routingModeChoice(mode)
                    }
                }
                if routingMode.requiresSelectedApps {
                    applicationPickerPanel
                } else if routingMode == .browserOnly {
                    HStack(spacing: 10) {
                        Image(systemName: "globe.badge.chevron.backward")
                            .foregroundStyle(SemiTheme.cyan)
                        Text("SemiVPN will route its local browser proxy through the VPN. Other applications remain on their normal connection.")
                            .font(.system(size: 11))
                            .foregroundStyle(SemiTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(28)
        }
    }

    private func routingModeChoice(_ mode: SharedConfig.RoutingMode) -> some View {
        let selected = routingMode == mode
        return Button {
            routingMode = mode
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: mode.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(mode.includesBrowser ? SemiTheme.violet : SemiTheme.cyan)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? SemiTheme.green : SemiTheme.textMuted)
                }
                Text(mode.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(mode.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SemiTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .padding(17)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? SemiTheme.panelRaised : SemiTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? (mode.includesBrowser ? SemiTheme.violet : SemiTheme.cyan).opacity(0.65) : SemiTheme.line, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .disabled(configurationLocked)
    }

    private var browserWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workspaceIntro(icon: "globe.badge.chevron.backward", title: "Browser domains", detail: "Manage the domains Chrome sends through SemiVPN. Select a browser-enabled mode in the Routing tab to use these rules.")
                domainRoutingPanel
                chromeExtensionPanel
            }
            .padding(28)
        }
        .onAppear {
            refreshDomains()
            refreshChromeExtensionStatus()
        }
    }

    private var domainRoutingPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Domains routed through VPN")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(domainRouting
                         ? "Used by Chrome in the \(routingMode.title) mode. Each rule includes the domain and www by default."
                         : "Saved for Chrome, but not used by the current \(routingMode.title) mode. Add subdomains only when you need the wider scope.")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                }
                Spacer()
                Text("127.0.0.1:\(SharedConfig.localProxyPort)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SemiTheme.cyan)
                Button("Refresh") {
                    refreshDomains()
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                TextField("example.com", text: $domainInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { requestAddDomain() }
                Button {
                    requestAddDomain()
                } label: {
                    Label("Add domain", systemImage: "plus")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let domainInputError {
                Text(domainInputError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if domains.isEmpty {
                emptyPanel(icon: "globe.badge.chevron.backward", title: "No domains added", detail: "Add a domain here or from the SemiVPN Chrome extension. Choose Selected apps + browser or Browser only in the Routing tab to use it.")
            } else {
                VStack(spacing: 7) {
                    ForEach(domains, id: \.self) { domain in
                        let enabled = !inactiveDomains.contains(domain)
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .foregroundStyle(SemiTheme.cyan)
                            Text(domain)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                            Text(subdomainDomains.contains(domain) ? "+ subdomains" : "domain + www")
                                .font(.system(size: 10))
                                .foregroundStyle(SemiTheme.textMuted)
                            Spacer()
                            Button {
                                setDomainEnabled(domain, enabled: !enabled)
                            } label: {
                                Image(systemName: enabled ? "checkmark.circle.fill" : "pause.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(enabled ? SemiTheme.green : .orange)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .help(enabled ? "Pause \(domain)" : "Resume \(domain)")
                            Button {
                                removeDomain(domain)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.red.opacity(0.85))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(SemiTheme.panelRaised.opacity(0.72)))
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
    }

    private var applicationPickerPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Applications routed through VPN")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Tick an application to include it in the native macOS per-app rule.")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                }
                Spacer()
                Button {
                    showAppPicker()
                } label: {
                    Label("Add application", systemImage: "plus")
                }
                .buttonStyle(AccentButtonStyle())
                .controlSize(.small)
                .disabled(configurationLocked)
            }
            if addedApps.isEmpty {
                emptyPanel(icon: "square.stack.3d.up", title: "No applications added", detail: "Add an .app bundle from Applications, then enable it here.")
            } else {
                VStack(spacing: 7) {
                    ForEach(addedApps.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { app in
                        appRoutingRow(app)
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
    }

    private func appRoutingRow(_ app: AppEntry) -> some View {
        HStack(spacing: 11) {
            Image(nsImage: appIcon(for: app))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(app.bundleIdentifier)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SemiTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Route", isOn: Binding(
                get: { selectedApps.contains(app.bundleIdentifier) || selectedApps.contains(app.signingIdentifier) },
                set: { on in
                    if on {
                        selectedApps.insert(app.bundleIdentifier)
                    } else {
                        selectedApps.remove(app.bundleIdentifier)
                        selectedApps.remove(app.signingIdentifier)
                    }
                    saveCurrentSelection()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(configurationLocked)
            Button {
                removeApp(app)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Remove \(app.name)")
            .disabled(configurationLocked)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(SemiTheme.panelRaised.opacity(0.72)))
    }

    private var profilesWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workspaceIntro(icon: "doc.on.doc.fill", title: "Profiles", detail: "Import and manage the OpenVPN configurations available to SemiVPN.")
                HStack(spacing: 10) {
                    Button {
                        showProfilePicker()
                    } label: {
                        Label("Import .ovpn", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(configurationLocked)
                    Button {
                        resetScanDialog()
                    } label: {
                        Label("Scan for profiles", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(configurationLocked)
                }
                if profiles.isEmpty {
                    emptyPanel(icon: "doc.badge.plus", title: "No profiles yet", detail: "Import a profile or scan the folders you choose. Profiles are stored privately in the app container.")
                } else {
                    VStack(spacing: 7) {
                        ForEach(profiles, id: \.self) { name in
                            profileWorkspaceRow(name)
                        }
                    }
                }
                Text("Profile identity is read from the certificate CN. The original .ovpn file is validated before it is stored.")
                    .font(.system(size: 11))
                    .foregroundStyle(SemiTheme.textMuted)
            }
            .padding(28)
        }
    }

    private func profileWorkspaceRow(_ name: String) -> some View {
        let meta = profileMeta(name)
        return HStack(spacing: 12) {
            Image(systemName: name == selectedProfile ? "checkmark.shield.fill" : "doc.text.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(name == selectedProfile ? SemiTheme.green : SemiTheme.violet)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(meta.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(meta.host)  ·  \(meta.protocolName)")
                    .font(.system(size: 10))
                    .foregroundStyle(SemiTheme.textMuted)
            }
            Spacer()
            if name == selectedProfile {
                Text("ACTIVE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(SemiTheme.green)
            } else {
                Button("Use profile") {
                    chooseProfile(name)
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .disabled(configurationLocked)
            }
            Button {
                deleteProfile(name)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Color.red.opacity(0.85))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(configurationLocked)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(name == selectedProfile ? SemiTheme.green.opacity(0.40) : SemiTheme.line))
    }

    private var diagnosticsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workspaceIntro(icon: "waveform.path.ecg", title: "Diagnostics", detail: "Confirm that the packet-tunnel extension, saved configuration, and native per-app rules are ready.")
                VStack(spacing: 0) {
                    diagnosticRow("Tunnel extension", detail: tunnelRegistered ? "Registered with macOS" : "Not registered", ok: tunnelRegistered, icon: "puzzlepiece.extension.fill")
                    diagnosticRow("VPN configuration", detail: vpnConfigSaved ? "Saved in Network Extension preferences" : "Not saved", ok: vpnConfigSaved, icon: "gearshape.2.fill")
                    diagnosticRow("Selected-app rules", detail: perAppConfigSaved ? "Native rules are saved" : "Not configured", ok: perAppConfigSaved, icon: "app.badge.checkmark.fill")
                    diagnosticRow("Live connection", detail: connectionStatusText, ok: vpnManager.status == .connected, icon: "antenna.radiowaves.left.and.right")
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Logging")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("Use extensive logs when diagnosing a connection or app-rule issue.")
                            .font(.system(size: 11))
                            .foregroundStyle(SemiTheme.textMuted)
                    }
                    Spacer()
                    Toggle("Extensive logging", isOn: $extensiveLogging)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(configurationLocked)
                        .onChange(of: extensiveLogging) { _, on in
                            AppLogger.enabled = on
                            AppLogger.log("extensive logging \(on ? "enabled" : "disabled")")
                        }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Application log")
                            .font(.system(size: 12, weight: .semibold))
                        Text(AppLogger.logURL?.path ?? "Unavailable")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(SemiTheme.textMuted)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Reveal log") { revealLogFile() }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.small)
                        .disabled(configurationLocked)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
                Button {
                    refreshStatuses()
                } label: {
                    Label("Refresh diagnostics", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(configurationLocked)
            }
            .padding(28)
        }
        .onAppear { refreshStatuses() }
    }

    private var connectionFooter: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(footerSummary)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(footerDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(SemiTheme.textMuted)
            }
            if connecting || vpnManager.status == .disconnecting {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            if isTunnelActive {
                Button(role: .destructive) {
                    vpnManager.stop()
                } label: {
                    Label("Disconnect", systemImage: "stop.fill")
                        .frame(minWidth: 126)
                }
                .buttonStyle(DisconnectButtonStyle())
            } else if vpnManager.status == .disconnecting {
                Text("Disconnecting…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SemiTheme.textMuted)
            } else {
                Button {
                    connect()
                } label: {
                    Label(connecting ? "Connecting…" : "Connect", systemImage: "bolt.fill")
                        .frame(minWidth: 126)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(selectedProfile == nil || connecting)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 15)
        .background(SemiTheme.sidebar.opacity(0.72))
    }

    private var sidebarSummary: String {
        if profiles.isEmpty { return "Import a profile to begin." }
        let appSummary: String
        switch routingMode {
        case .allApps:
            appSummary = "All app traffic is covered by the VPN."
        case .selectedAppsOnly, .selectedAppsAndBrowser:
            appSummary = selectedApps.isEmpty ? "No app rules are enabled." : "\(selectedApps.count) app rule\(selectedApps.count == 1 ? "" : "s") enabled."
        case .browserOnly:
            appSummary = "Other applications stay direct."
        }
        let browserSummary = domainRouting
            ? "\(domains.count) browser domain rule\(domains.count == 1 ? "" : "s") enabled."
            : "Browser domain routing is off."
        return "\(appSummary)\n\(browserSummary)"
    }

    private var connectionHeroDetail: String {
        let endpoint = selectedProfile.map(profileEndpointLabel)
        if isTunnelActive {
            return (endpoint.map { $0 + " · " } ?? "") + routingMode.detail + " VPN connection is active."
        }
        return endpoint.map { $0 + " · ready for a secure connection." }
            ?? "Choose a profile and routing policy to begin."
    }

    private var overviewConnectionIdentity: String {
        guard let selectedProfile else { return "No profile selected" }
        let meta = profileMeta(selectedProfile)
        return "\(profileEndpointLabel(selectedProfile)) · \(meta.protocolName)"
    }

    private var overviewConnectionDescription: String {
        if isTunnelActive {
            return "Routing mode is locked while connected. Domain rules can be changed in the Browser tab."
        }
        if profiles.isEmpty { return "Import an OpenVPN profile to enable Connect." }
        return routingMode.detail
    }

    private var footerDetail: String {
        if isTunnelActive { return "Routing mode is locked while connected. Domain rules can be changed in the Browser tab." }
        if profiles.isEmpty { return "Import an OpenVPN profile to enable Connect." }
        return routingMode.detail
    }

    private func workspaceIntro(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SemiTheme.cyan)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(SemiTheme.cyan.opacity(0.13)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SemiTheme.textMuted)
            }
        }
    }

    private func metricTile<MenuContent: View>(
        _ label: String,
        value: String,
        icon: String,
        tint: Color,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
                Menu {
                    menuContent()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SemiTheme.textMuted)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(SemiTheme.panelRaised.opacity(0.82)))
                }
                .menuStyle(.borderlessButton)
                .help("Configure \(label.lowercased())")
            }
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(SemiTheme.textMuted)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 13).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(SemiTheme.line))
    }

    private func diagnosticRow(_ label: String, detail: String, ok: Bool, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(SemiTheme.textMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(SemiTheme.textMuted)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? SemiTheme.green : Color.orange)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(SemiTheme.line).frame(height: 1) }
    }

    private func infoCallout(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SemiTheme.textMuted)
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.28)))
    }

    private func emptyPanel(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(SemiTheme.violet)
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(SemiTheme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 31)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 14).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SemiTheme.line))
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 55)
            BrandMark(size: 72)
            Text("Ready when you are")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Import an OpenVPN profile to configure routing and connect securely.")
                .font(.system(size: 12))
                .foregroundStyle(SemiTheme.textMuted)
            HStack(spacing: 10) {
                Button {
                    showProfilePicker()
                } label: {
                    Label("Import .ovpn", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(AccentButtonStyle())
                Button {
                    resetScanDialog()
                } label: {
                    Label("Scan for profiles", systemImage: "magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Spacer(minLength: 55)
        }
        .frame(maxWidth: .infinity)
        .padding(25)
        .background(RoundedRectangle(cornerRadius: 16).fill(SemiTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(SemiTheme.line))
    }

    private func resetScanDialog() {
        discoveredProfiles = []
        selectedScanProfiles = []
        scanning = false
        showScanResults = false
        scanDesktop = true
        scanDocuments = true
        scanDownloads = true
        scanOpenVPN = false
        showScanDialog = true
    }

    private var scanDialog: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Scan for profiles")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                if showScanResults && !scanning {
                    Text("\(discoveredProfiles.count) found")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SemiTheme.cyan)
                }
            }
            if !showScanResults {
                Text("Choose where SemiVPN should look for .ovpn files. macOS will ask for access only when a location is selected.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("Desktop", isOn: $scanDesktop)
                Toggle("Documents", isOn: $scanDocuments)
                Toggle("Downloads", isOn: $scanDownloads)
                if openVPNClientInstalled { Toggle("OpenVPN Client App", isOn: $scanOpenVPN) }
                HStack {
                    Spacer()
                    Button("Cancel") { showScanDialog = false }
                    Button("Scan") { performScan() }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(!scanDesktop && !scanDocuments && !scanDownloads && !scanOpenVPN)
                }
            } else if scanning {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Scanning selected locations…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 22)
            } else if discoveredProfiles.isEmpty {
                Text("No .ovpn profiles found in the selected locations.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 22)
                HStack { Spacer(); Button("Close") { showScanDialog = false }.buttonStyle(SecondaryButtonStyle()) }
            } else {
                Toggle("Select all", isOn: Binding(
                    get: { selectedScanProfiles.count == discoveredProfiles.count },
                    set: { selectedScanProfiles = $0 ? Set(discoveredProfiles) : [] }
                ))
                .toggleStyle(.checkbox)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(discoveredProfiles, id: \.self) { url in
                            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                            let name = importName(for: url, text: text)
                            let host = (try? OVPNParser().parse(text))?.remotes.first?.host ?? "unknown"
                            Toggle(isOn: Binding(
                                get: { selectedScanProfiles.contains(url) },
                                set: { on in
                                    if on { selectedScanProfiles.insert(url) } else { selectedScanProfiles.remove(url) }
                                }
                            )) {
                                HStack { ProfileRowView(name: name, host: host, protocolName: url.lastPathComponent); Spacer(); locationBadge(for: url) }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 190)
                HStack {
                    Spacer()
                    Button("Cancel") { showScanDialog = false }
                    Button("Import") {
                        importSelectedProfiles()
                        showScanDialog = false
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(selectedScanProfiles.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 470)
        .preferredColorScheme(.dark)
    }

    /// Shown when no profiles exist: only the Import / Search card, centered.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 3) {
                Text("No profiles yet")
                    .font(.title3.weight(.semibold))
                Text("Import an OpenVPN profile to get started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Import .ovpn…") { showProfilePicker() }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                Button("Scan for profiles…") {
                    // Start the dialog from scratch every time.
                    discoveredProfiles = []
                    selectedScanProfiles = []
                    scanning = false
                    showScanResults = false
                    scanDesktop = true
                    scanDocuments = true
                    scanDownloads = true
                    scanOpenVPN = false
                    showScanDialog = true
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Glass card container

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        )
    }

    private func sectionHeader(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("SemiVPN").font(.title3.bold())
                Text("Per-app OpenVPN routing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .sheet(isPresented: $showSettings) {
                settingsDialog
            }
        }
        .padding(.top, 30)   // room for the traffic lights
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(WindowDragView())
    }

    /// Makes the window draggable by its header (no title bar with
    /// `.hiddenTitleBar`).
    private struct WindowDragView: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                view.window?.isMovableByWindowBackground = true
            }
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private var statusBadge: some View {
        let (text, color) = statusInfo
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundStyle(color)
    }

    private var statusInfo: (String, Color) {
        switch displayedVPNStatus {
        case .connected: return ("Connected", .green)
        case .connecting: return ("Connecting…", .orange)
        case .disconnecting: return ("Disconnecting…", .orange)
        case .disconnected: return ("Disconnected", .secondary)
        case .invalid:
            return vpnManager.hasSavedConfiguration
                ? ("Disconnected", .secondary)
                : ("Not configured", .secondary)
        case .reasserting: return ("Reconnecting…", .orange)
        @unknown default: return ("Unknown", .secondary)
        }
    }

    /// The connect action starts before Network Extension publishes its first
    /// `.connecting` event. Keep the top status badge aligned with the button
    /// during that propagation window instead of showing stale Disconnected.
    private var displayedVPNStatus: NEVPNStatus {
        if connecting && (vpnManager.status == .disconnected || vpnManager.status == .invalid) {
            return .connecting
        }
        return vpnManager.status
    }

    // MARK: - Profile

    private var profileCard: some View {
        card {
            sectionHeader("doc.on.doc", "Profile")
            profileDropdown
        }
    }

    /// Rich multi-line profile dropdown: name, server IP and protocol are
    /// visible both in the closed state and in the open options list.
    private var profileDropdown: some View {
        VStack(spacing: 0) {
            Button {
                showProfileMenu.toggle()
            } label: {
                if let selectedProfile {
                    let meta = profileMeta(selectedProfile)
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12))
                            .foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meta.displayName)
                                .font(.body)
                                .fontWeight(.medium)
                            HStack(spacing: 5) {
                                Image(systemName: "globe")
                                    .font(.system(size: 9))
                                Text(meta.host)
                                Text("·")
                                Text(meta.protocolName)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.15))
                    )
                    .contentShape(Rectangle())
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Select a profile…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.15))
                    )
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showProfileMenu, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    ForEach(profiles, id: \.self) { name in
                        HStack(spacing: 4) {
                            Button {
                                selectedProfile = name
                                showProfileMenu = false
                            } label: {
                                HStack(spacing: 10) {
                                    if name == selectedProfile {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.indigo)
                                            .frame(width: 12)
                                    } else {
                                        Color.clear.frame(width: 12)
                                    }
                                    ProfileRowView(name: profileMeta(name).displayName,
                                                    host: profileMeta(name).host,
                                                    protocolName: profileMeta(name).protocolName)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                deleteProfile(name)
                                showProfileMenu = false
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red.opacity(0.75))
                            }
                            .buttonStyle(.borderless)
                            .help("Delete \(profileMeta(name).displayName)")
                            .padding(.trailing, 8)
                        }
                        if name != profiles.last {
                            Divider().opacity(0.4)
                        }
                    }
                    if profiles.isEmpty {
                        Text("No profiles yet — import an .ovpn file")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .padding(4)
                .frame(width: 340)
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Reads a profile's metadata for the picker rows.
    private func profileMeta(_ name: String) -> ProfileMeta {
        let fallback = name.replacingOccurrences(of: ".ovpn", with: "")
        guard let text = SharedConfig.loadProfile(name: name) else {
            return ProfileMeta(displayName: fallback, host: "unknown", protocolName: "OpenVPN")
        }
        let cn = profileName(from: text) ?? fallback
        guard let profile = try? OVPNParser().parse(text),
              let remote = profile.remotes.first else {
            return ProfileMeta(displayName: cn, host: "unknown", protocolName: "OpenVPN")
        }
        return ProfileMeta(displayName: cn, host: remote.host,
                           protocolName: "OpenVPN \(profile.transport.rawValue.uppercased())")
    }

    private func profileEndpointLabel(_ name: String) -> String {
        let meta = profileMeta(name)
        return "\(meta.host) [\(meta.displayName)]"
    }

    /// The name to use when importing a profile file: the certificate's
    /// subject CN (the OpenVPN Connect JSON name is just "host [CN]", both
    /// of which we derive from the profile itself).
    private func importName(for url: URL, text: String) -> String {
        profileName(from: text) ?? url.deletingPathExtension().lastPathComponent
    }

    /// The discovery location of a scanned profile.
    private func locationLabel(for url: URL) -> String {
        let path = url.deletingLastPathComponent().path
        if path.contains("/Desktop") { return "Desktop" }
        if path.contains("/Documents") { return "Documents" }
        if path.contains("/Downloads") { return "Downloads" }
        if path.contains("OpenVPN Connect") { return "OpenVPN Client" }
        return url.deletingLastPathComponent().lastPathComponent
    }

    private func locationBadge(for url: URL) -> some View {
        Text(locationLabel(for: url))
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(SemiTheme.violet.opacity(0.17)))
            .foregroundStyle(SemiTheme.violet)
            .lineLimit(1)
    }

    /// Extracts the client certificate's Subject CN — that is the profile
    /// name. The subject's attributes come after the issuer's in the DER,
    /// so the last commonName wins.
    private func profileName(from text: String) -> String? {
        guard let range = text.range(of: "<cert>") else { return nil }
        let block = text[range.upperBound...]
        guard let end = block.range(of: "</cert>") else { return nil }
        let inner = block[..<end.lowerBound]
        // Some profiles embed an `openssl x509` text dump before the PEM;
        // only decode from the BEGIN line onwards.
        guard let begin = inner.range(of: "-----BEGIN CERTIFICATE-----") else { return nil }
        let pem = inner[begin.upperBound...]
        let lines = pem.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
        guard let der = Data(base64Encoded: lines.joined()) else { return nil }
        let bytes = [UInt8](der)
        // The commonName attribute OID (2.5.4.3 = 55 04 03) followed by the
        // value tag (UTF8String 0x0C or PrintableString 0x13) and its
        // length (short or long form).
        // The subject's commonName is the SECOND occurrence in the DER:
        // the order is [issuer CN][subject CN][authority-key-id CN].
        var found: [String] = []
        var i = 0
        while i < bytes.count - 3 {
            if bytes[i] == 0x55 && bytes[i + 1] == 0x04 && bytes[i + 2] == 0x03 {
                let j = i + 3
                if j + 1 < bytes.count, bytes[j] == 0x0C || bytes[j] == 0x13 {
                    var len = 0
                    var k = j + 1
                    if bytes[k] & 0x80 == 0 {
                        len = Int(bytes[k])
                        k += 1
                    } else {
                        let count = Int(bytes[k] & 0x7F)
                        k += 1
                        guard count <= 4, k + count <= bytes.count else { i += 1; continue }
                        for _ in 0..<count {
                            len = (len << 8) | Int(bytes[k])
                            k += 1
                        }
                    }
                    guard len > 0, k + len <= bytes.count else { i += 1; continue }
                    if let cn = String(bytes: bytes[k..<(k + len)], encoding: .utf8),
                       !cn.trimmingCharacters(in: .whitespaces).isEmpty {
                        found.append(cn)
                    }
                }
            }
            i += 1
        }
        if found.count >= 2 { return found[1] }
        return found.last
    }

    private struct ProfileMeta {
        var displayName: String
        var host: String
        var protocolName: String
    }

    /// The unified profile card: name on the first line, the server address
    /// and protocol on the second. Used in the dropdown, the scan results
    /// and the import confirmation.
    private struct ProfileRowView: View {
        let name: String
        let host: String
        let protocolName: String

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 9))
                    Text(host)
                    Text("·")
                    Text(protocolName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    /// Multi-line profile row used inside the picker menu.
    private struct ProfileOptionView: View {
        let meta: ProfileMeta

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.displayName)
                    .font(.body)
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 9))
                    Text(meta.host)
                    Text("·")
                    Text(meta.protocolName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Routing

    private var routingCard: some View {
        card {
            HStack {
                sectionHeader("arrow.left.arrow.right", "Routing")
                Spacer()
                Picker("Mode", selection: $routingMode) {
                    ForEach(SharedConfig.RoutingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 420)
            }
            Label(routingMode.detail, systemImage: routingMode.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Apps

    private var appsCard: some View {
        card {
            HStack(alignment: .center) {
                sectionHeader("app.badge.checkmark", "Apps routed through the VPN")
                Spacer()
                Button("Add application…") { showAppPicker() }
                    .controlSize(.small)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let apps = addedApps.values.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    ForEach(apps) { app in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(
                                get: { selectedApps.contains(app.bundleIdentifier) || selectedApps.contains(app.signingIdentifier) },
                                set: { on in
                                    if on {
                                        selectedApps.insert(app.bundleIdentifier)
                                    } else {
                                        selectedApps.remove(app.bundleIdentifier)
                                        selectedApps.remove(app.signingIdentifier)
                                    }
                                    saveCurrentSelection()
                                }
                            )) {
                                HStack(spacing: 8) {
                                    Image(nsImage: appIcon(for: app))
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                    Text(app.name)
                                        .lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Button {
                                removeApp(app)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(app.name) from the list")
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
            if addedApps.isEmpty {
                Text("No apps added yet — click “Add application…” to pick an app to route through the VPN. Nothing tunnels until you add and tick one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(addedApps.count) application\(addedApps.count == 1 ? "" : "s") — tick an app to route it through the VPN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Import

    private var importCard: some View {
        card {
            HStack {
                sectionHeader("square.and.arrow.down", "Import / Search Profiles")
                Spacer()
                Button("Import .ovpn…") { showProfilePicker() }
                    .controlSize(.small)
                Button("Scan for profiles…") {
                    // Start the dialog from scratch every time.
                    discoveredProfiles = []
                    selectedScanProfiles = []
                    scanning = false
                    showScanResults = false
                    scanDesktop = true
                    scanDocuments = true
                    scanDownloads = true
                    scanOpenVPN = false
                    showScanDialog = true
                }
                .controlSize(.small)
            }
            Text("Finds .ovpn profile files in the locations you choose. Reading the OpenVPN Client App folder asks for your permission first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(footerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if connecting {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            if isTunnelActive {
                Button(role: .destructive) {
                    vpnManager.stop()
                } label: {
                    Label("Disconnect", systemImage: "stop.fill")
                }
            } else if vpnManager.status == .disconnecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Disconnecting…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    connect()
                } label: {
                    Label(connecting ? "Connecting…" : "Connect", systemImage: "bolt.fill")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(selectedProfile == nil || connecting)
            }
        }
        .padding(.vertical, 14)
    }

    private var footerSummary: String {
        let profile = selectedProfile ?? "No profile selected"
        return "\(profile) · \(routingMode.title)"
    }

    private var isTunnelActive: Bool {
        vpnManager.status == .connected
            || vpnManager.status == .connecting
            || vpnManager.status == .reasserting
    }

    /// Freeze all configuration controls while the tunnel is being started,
    /// connected, or stopped. The footer keeps Disconnect available while
    /// the tunnel is active.
    private var configurationLocked: Bool {
        connecting || vpnManager.status == .connected
            || vpnManager.status == .connecting
            || vpnManager.status == .reasserting
            || vpnManager.status == .disconnecting
    }

    // MARK: - Settings dialog

    private var settingsDialog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Refresh") { refreshStatuses() }
                    .controlSize(.small)
                    .disabled(configurationLocked)
            }
            Divider()
            statusRow("Tunnel extension",
                      ok: tunnelRegistered,
                      detail: tunnelRegistered ? "registered" : "not registered")
            statusRow("Selected-app rules",
                      ok: perAppConfigSaved,
                      detail: perAppConfigSaved ? "saved" : "not configured")
            statusRow("VPN configuration",
                      ok: vpnConfigSaved,
                      detail: vpnConfigSaved ? "saved" : "not saved")
            statusRow("Connection",
                      ok: vpnManager.status == .connected,
                      detail: connectionStatusText)
            Divider()
            Toggle("Extensive logging", isOn: $extensiveLogging)
                .disabled(configurationLocked)
                .onChange(of: extensiveLogging) { _, on in
                    AppLogger.enabled = on
                    AppLogger.log("extensive logging \(on ? "enabled" : "disabled")")
                }
            Toggle("Start SemiVPN at login", isOn: Binding(
                get: { launchAtLogin },
                set: { updateLaunchAtLogin($0) }
            ))
            .disabled(configurationLocked)
            Text(launchAtLoginError ?? launchAtLoginStatusDescription)
                .font(.caption)
                .foregroundStyle(launchAtLoginError == nil ? Color.secondary : Color.red)
            Text("Log file:\n\(AppLogger.logURL?.path ?? "unavailable")")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Show Log File") { revealLogFile() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(configurationLocked)
                Spacer()
                Button("Close") { showSettings = false }
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            refreshStatuses()
            launchAtLogin = (NSApp.delegate as? AppDelegate)?.launchAtLoginEnabled ?? true
            launchAtLoginError = nil
        }
    }

    private var chromeExtensionSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chrome extension")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: chromeExtensionReady ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(chromeExtensionReady ? Color.green : Color.secondary)
                Button(chromeExtensionReady ? "Re-sync / Update" : "Prepare") {
                    prepareChromeExtension()
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
            }
            Text(chromeExtensionError ?? (chromeExtensionReady
                 ? "Ready to load in Chrome with Developer mode."
                 : "Copies the offline extension to a stable folder on this Mac."))
                .font(.caption)
                .foregroundStyle(chromeExtensionError == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            Text((chromeExtensionDirectory ?? ChromeExtensionInstaller.installedDirectoryURL).path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SemiTheme.textMuted)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button("Open Chrome setup") {
                    ChromeExtensionInstaller.openChromeExtensionSettings()
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                Button("Reveal folder") {
                    ChromeExtensionInstaller.revealInstalledDirectory()
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
            }
            Text("In Chrome: enable Developer mode, choose Load unpacked, and select the folder above. This is required once per Mac.")
                .font(.system(size: 10))
                .foregroundStyle(SemiTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func refreshDomains() {
        let configuration = SharedConfig.loadDomainConfiguration()
        domains = configuration.domains
        subdomainDomains = Set(configuration.subdomainDomains)
        inactiveDomains = Set(configuration.inactiveDomains)
        domainInputError = nil
    }

    private var launchAtLoginStatusDescription: String {
        (NSApp.delegate as? AppDelegate)?.launchAtLoginStatusDescription
            ?? "Login item status is unavailable."
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            launchAtLoginError = "Login item status is unavailable."
            return
        }
        switch appDelegate.setLaunchAtLogin(enabled) {
        case .success:
            launchAtLogin = enabled
            launchAtLoginError = nil
        case .failure(let error):
            launchAtLogin = appDelegate.launchAtLoginEnabled
            launchAtLoginError = error.localizedDescription
        }
    }

    private func refreshChromeExtensionStatus() {
        _ = ChromeExtensionInstaller.syncInstalledExtensionIfNeeded()
        let directory = ChromeExtensionInstaller.installedDirectoryURL
        chromeExtensionDirectory = ChromeExtensionInstaller.isPrepared ? directory : nil
        chromeExtensionReady = ChromeExtensionInstaller.isPrepared
        chromeExtensionError = nil
    }

    private func prepareChromeExtension() {
        do {
            let directory = try ChromeExtensionInstaller.prepare()
            chromeExtensionDirectory = directory
            chromeExtensionReady = true
            chromeExtensionError = nil
            AppLogger.log("Chrome extension prepared at \(directory.path)")
            ChromeExtensionInstaller.openChromeExtensionSettings()
        } catch {
            chromeExtensionReady = false
            chromeExtensionError = error.localizedDescription
            AppLogger.log("Chrome extension preparation failed: \(error.localizedDescription)")
        }
    }

    private func refresh() {
        profiles = SharedConfig.profileNames()
        refreshDomains()
        refreshChromeExtensionStatus()
        vpnManager.loadSelection()
        if let selection = vpnManager.selection,
           profiles.contains(selection.profileName) {
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
            // Stale selection (profile was deleted) — show nothing.
            selectedProfile = nil
            selectedApps = []
            routingMode = .allApps
            addedApps = [:]
            if let first = profiles.first {
                selectedProfile = first
            }
        }
    }

    private func saveCurrentSelection() {
        guard let selectedProfile else { return }
        vpnManager.saveSelection(
            profileName: selectedProfile,
            // Keep the user's app choices while switching modes. All apps
            // and Browser only ignore this list when building tunnel rules,
            // so returning to a selected-app mode does not lose the choices.
            appIdentifiers: Array(selectedApps),
            routingMode: routingMode,
            appEntries: Array(addedApps.values)
        )
    }

    private func chooseProfile(_ name: String) {
        guard profiles.contains(name), name != selectedProfile else { return }
        selectedProfile = name
        saveCurrentSelection()
        AppLogger.log("selected profile: \(name)")
    }

    private func requestAddDomain() {
        guard let normalized = SharedConfig.routingDomain(domainInput) else {
            domainInputError = SharedConfig.DomainError.invalidDomain.localizedDescription
            return
        }
        if domains.contains(normalized) || domains.contains("www." + normalized) {
            domainInputError = "That domain is already in the domain list."
            return
        }
        pendingDomainToAdd = normalized
        domainInputError = nil
        showDomainSubdomainPrompt = true
    }

    private func commitDomain(_ domain: String, includeSubdomains: Bool) {
        do {
            let configuration = try SharedConfig.addDomain(domain, includeSubdomains: includeSubdomains)
            domains = configuration.domains
            subdomainDomains = Set(configuration.subdomainDomains)
            inactiveDomains = Set(configuration.inactiveDomains)
            domainInput = ""
            domainInputError = nil
            AppLogger.log("added domain rule: \(domain) scope=\(includeSubdomains ? "subdomains" : "domain-and-www")")
        } catch {
            domainInputError = error.localizedDescription
        }
    }

    private func removeDomain(_ domain: String) {
        do {
            let configuration = try SharedConfig.removeDomain(domain)
            domains = configuration.domains
            subdomainDomains = Set(configuration.subdomainDomains)
            inactiveDomains = Set(configuration.inactiveDomains)
            AppLogger.log("removed domain rule: \(domain)")
        } catch {
            domainInputError = error.localizedDescription
        }
    }

    private func setDomainEnabled(_ domain: String, enabled: Bool) {
        do {
            let configuration = try SharedConfig.setDomainEnabled(domain, enabled: enabled)
            domains = configuration.domains
            subdomainDomains = Set(configuration.subdomainDomains)
            inactiveDomains = Set(configuration.inactiveDomains)
            AppLogger.log("domain rule \(enabled ? "enabled" : "paused"): \(domain)")
        } catch {
            domainInputError = error.localizedDescription
        }
    }

    private func connect() {
        guard let selectedProfile else { return }
        errorMessage = nil
        connecting = true
        AppLogger.log("connect requested: profile=\(selectedProfile) mode=\(routingMode.rawValue) apps=\(selectedApps.count)")
        saveCurrentSelection()
        Task {
            do {
                try await vpnManager.start()
                AppLogger.log("connect started")
            } catch {
                errorMessage = "Failed to start VPN: \(error.localizedDescription)"
                showConnectError = true
                AppLogger.log("connect failed: \(error)")
            }
            connecting = false
        }
    }

    // MARK: - Profile import

    private func showProfilePicker() {
        AppLogger.log("import button clicked")
        let panel = NSOpenPanel()
        panel.title = "Select an OpenVPN profile"
        panel.message = "semi-vpn imports your OpenVPN configuration (.ovpn) and stores it privately in its app container."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ovpn") ?? .data]
        present(panel) { response in
            AppLogger.log("panel response \(response.rawValue)")
            if response == .OK, let url = panel.url {
                importProfile(from: url)
            }
        }
    }

    private func present(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        AppLogger.log("presenting panel, keyWindow=\(NSApp.keyWindow != nil)")
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response)
            }
        } else {
            completion(panel.runModal())
        }
    }

    private enum ScanSource {
        case desktop
        case documents
        case downloads
        case openVPN
    }

    /// True when the OpenVPN Connect client is installed (its profiles
    /// folder is only scanned with explicit user consent).
    private var openVPNClientInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.openvpn.connect.app") != nil
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.openvpn.client.app") != nil
    }

    private func performScan() {
        showScanResults = true
        scanning = true
        selectedScanProfiles = []
        Task {
            var found: [URL] = []
            if scanDesktop { found.append(contentsOf: scan(.desktop)) }
            if scanDocuments { found.append(contentsOf: scan(.documents)) }
            if scanDownloads { found.append(contentsOf: scan(.downloads)) }
            if openVPNClientInstalled && scanOpenVPN { found.append(contentsOf: scan(.openVPN)) }
            discoveredProfiles = found
            selectedScanProfiles = Set(found)
            scanning = false
        }
    }

    private func scan(_ source: ScanSource) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        let dir: String
        switch source {
        case .desktop:
            dir = NSHomeDirectory() + "/Desktop"
        case .documents:
            dir = NSHomeDirectory() + "/Documents"
        case .downloads:
            dir = NSHomeDirectory() + "/Downloads"
        case .openVPN:
            dir = NSHomeDirectory() + "/Library/Application Support/OpenVPN Connect/profiles"
        }
        // The access is attempted only after the user chose this source, so
        // the system permission prompt appears exactly then.
        if let files = try? fm.contentsOfDirectory(atPath: dir) {
            for file in files where file.hasSuffix(".ovpn") {
                let url = URL(fileURLWithPath: dir + "/" + file)
                if !found.contains(url) { found.append(url) }
            }
        }
        return found
    }

    /// Imports all profiles ticked in the scan dialog (no name prompt —
    /// the file's base name is used, deduplicated).
    private func importSelectedProfiles() {
        for url in selectedScanProfiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            importProfile(from: url, askName: false)
        }
        profiles = SharedConfig.profileNames()
    }

    private func importProfile(from url: URL, askName: Bool = true) {
        AppLogger.log("importing profile: \(url.lastPathComponent)")
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            _ = try OVPNParser().parse(text)  // validate
        } catch {
            importError = "Invalid profile: \(error.localizedDescription)"
            showImportError = true
            return
        }

        var name = importName(for: url, text: text)
        if askName {
            // Confirmation with the profile's identity — the name comes
            // from the certificate CN automatically.
            let profile = try? OVPNParser().parse(text)
            let host = profile?.remotes.first?.host ?? "unknown"
            let protocolName = profile.map { "OpenVPN \($0.transport.rawValue.uppercased())" } ?? "OpenVPN"

            let alert = NSAlert()
            alert.messageText = "Add this profile?"
            alert.informativeText = url.lastPathComponent

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            let detailLabel = NSTextField(labelWithString: "🌐 \(host)  ·  \(protocolName)")
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
            profiles = SharedConfig.profileNames()
            selectedProfile = name + ".ovpn"
        } else {
            importError = "Failed to store the profile."
            showImportError = true
        }
    }

    // MARK: - App picker

    private func showAppPicker() {
        let panel = NSOpenPanel()
        panel.title = "Add an application"
        panel.message = "Pick an application to route it through the VPN. Only the apps you add here are ever considered — nothing else is scanned."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        present(panel) { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url),
                      let identifier = bundle.bundleIdentifier else { continue }
                let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? url.lastPathComponent
                let entry = AppEntry(
                    name: name,
                    bundleIdentifier: identifier,
                    signingIdentifier: identifier,
                    path: url.path,
                    designatedRequirement: AppCodeSignature.designatedRequirement(for: url)
                )
                addedApps[identifier] = entry
                selectedApps.insert(identifier)
                saveCurrentSelection()
            }
        }
    }

    private func appIcon(for app: AppEntry) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.path)
    }

    private func removeApp(_ app: AppEntry) {
        addedApps.removeValue(forKey: app.bundleIdentifier)
        selectedApps.remove(app.bundleIdentifier)
        selectedApps.remove(app.signingIdentifier)
        saveCurrentSelection()
        AppLogger.log("removed app \(app.name)")
    }

    private func deleteProfile(_ name: String) {
        let meta = profileMeta(name)
        let alert = NSAlert()
        alert.messageText = "Delete profile?"
        alert.informativeText = "Remove “\(meta.displayName)” (\(meta.host))? This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SharedConfig.deleteProfile(name: name)
        if selectedProfile == name {
            selectedProfile = nil
            selectedApps = []
        }
        profiles = SharedConfig.profileNames()
        AppLogger.log("deleted profile \(name)")
    }

    private func revealLogFile() {
        AppLogger.log("reveal log file")
        guard let url = AppLogger.logURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - Settings statuses

    private var connectionStatusText: String {
        switch vpnManager.status {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .disconnecting: return "disconnecting…"
        case .reasserting: return "reconnecting…"
        case .invalid: return vpnManager.hasSavedConfiguration ? "disabled" : "not configured"
        case .disconnected: return "disconnected"
        @unknown default: return "unknown"
        }
    }

    private func statusRow(_ label: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Whether the given extension is registered (and therefore approved)
    /// with the system's plugin manager.
    private func extensionRegistered(bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", bundleID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.contains(bundleID) ?? false
    }

    private func refreshStatuses() {
        tunnelRegistered = extensionRegistered(bundleID: "com.semivpn.app.TunnelProvider")
        Task {
            let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
            vpnConfigSaved = managers?.contains(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == "com.semivpn.app.TunnelProvider"
            }) ?? false
            perAppConfigSaved = managers?.contains(where: {
                guard ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == "com.semivpn.app.TunnelProvider" else { return false }
                return $0.routingMethod == .sourceApplication && ($0.copyAppRules()?.isEmpty == false)
            }) ?? false
        }
    }

    // MARK: - Error dialog

    /// Small dialog with selectable (copyable) error text.
    private struct ErrorDialog: View {
        let title: String
        let message: String
        let onClose: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(message)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(6)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                    Spacer()
                    Button("OK") { onClose() }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }
}

private struct BrandMark: View {
    var size: CGFloat = 39

    var body: some View {
        Group {
            if let image = bundledBrandImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.58, green: 0.28, blue: 1.0), Color(red: 0.12, green: 0.82, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "shield.checkered")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        .shadow(color: Color(red: 0.18, green: 0.65, blue: 1.0).opacity(0.24), radius: size * 0.18, y: size * 0.08)
    }

    private var bundledBrandImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon-v2", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
