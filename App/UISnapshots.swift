#if DEBUG
import AppKit
import NetworkExtension
import SwiftUI

/// Draws the app's screens with sample data into PNG files, in light and
/// dark mode, for reviewing the design: `SemiVPN --render-ui <folder>`
/// (Scripts/ui-snapshots.sh). Nothing on the system is read or changed, and
/// no window appears.
enum UISnapshots {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-ui"), index + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        MainActor.assumeIsolated {
            render(into: folder)
        }
        exit(0)
    }

    private struct Screen {
        let name: String
        let width: CGFloat
        /// Nil: as tall as the content wants.
        var height: CGFloat? = nil
        let view: @MainActor () -> AnyView
    }

    @MainActor
    private static var screens: [Screen] {
        [
            Screen(name: "window-connected-websites", width: 400, height: 760) {
                window(AppModel(preview: sample(status: .connected, mode: .browserOnly)))
            },
            Screen(name: "window-websites-extension-not-set-up", width: 400, height: 760) {
                extensionState(.notSetUp)
                return window(AppModel(preview: sample(status: .disconnected, mode: .selectedAppsAndBrowser)))
            },
            Screen(name: "window-websites-extension-update", width: 400, height: 760) {
                extensionState(.updateNeeded)
                return window(AppModel(preview: sample(status: .connected, mode: .selectedAppsAndBrowser)))
            },
            Screen(name: "window-apps", width: 400, height: 760) {
                window(AppModel(preview: sample(status: .disconnected, mode: .selectedAppsAndBrowser, list: .apps)))
            },
            Screen(name: "window-add-website", width: 400, height: 760) {
                var preview = sample(status: .disconnected, mode: .selectedAppsAndBrowser)
                preview.listSearch = "status.example"
                return window(AppModel(preview: preview))
            },
            Screen(name: "window-pending-apps", width: 400, height: 760) {
                var preview = sample(status: .connected, mode: .selectedAppsAndBrowser, list: .apps)
                // The tunnel runs with one app fewer than now switched on.
                let enabled = preview.apps.filter(\.enabled).map(\.entry.bundleIdentifier)
                preview.appliedRouting = .init(profileName: "gobritanya.ovpn", routingMode: .selectedAppsAndBrowser,
                                               appIdentifiers: Array(enabled.dropFirst()))
                return window(AppModel(preview: preview))
            },
            Screen(name: "menubar-pending-profile-route", width: 340) {
                var preview = sample(status: .connected, mode: .selectedAppsAndBrowser)
                preview.appliedRouting = .init(profileName: "nyks-office.ovpn", routingMode: .browserOnly, appIdentifiers: [])
                return AnyView(MenuBarPanel().environmentObject(AppModel(preview: preview)))
            },
            Screen(name: "window-connecting-all-apps", width: 400, height: 520) {
                window(AppModel(preview: sample(status: .connecting, mode: .allApps)))
            },
            Screen(name: "window-empty-list", width: 400, height: 560) {
                var preview = sample(status: .disconnected, mode: .browserOnly)
                preview.domains = []
                return window(AppModel(preview: preview))
            },
            Screen(name: "window-welcome", width: 400, height: 560) {
                window(AppModel(preview: AppModel.Preview()))
            },
            Screen(name: "menubar-connected", width: 340) {
                AnyView(MenuBarPanel()
                    .environmentObject(AppModel(preview: sample(status: .connected, mode: .selectedAppsAndBrowser))))
            },
            Screen(name: "notices", width: 400) {
                AnyView(VStack(spacing: 12) {
                    NoticeCard(icon: "lock.shield", tint: SemiTheme.amber,
                               title: "Allow SemiVPN’s network extension",
                               detail: "macOS needs your permission once. In System Settings → General → Login Items & Extensions → Network Extensions, turn on SemiVPN.") {
                        Button("Open System Settings") {}.buttonStyle(.borderedProminent)
                    }
                    RoutingRepairBanner(blocksListedSites: false, phase: .idle) {}
                    NoticeCard(icon: "arrow.triangle.2.circlepath.circle.fill", tint: SemiTheme.amber,
                               title: "Update the browser extension in Google Chrome",
                               detail: "Google Chrome runs 0.4.0 (3ca243a); SemiVPN installed 0.4.1 (8be21f0). On the Extensions page, click ↻ on “SemiVPN Domain Routing”.") {
                        Button("Open Extensions Page") {}.buttonStyle(.borderedProminent)
                        Button("Show Steps") {}
                    }
                }
                .padding(20))
            },
        ] + SettingsWindowController.Tab.allCases.map { tab in
            Screen(name: "settings-\(tab.title.lowercased())", width: 500) {
                AnyView(SettingsTabView(tab: tab)
                    .environmentObject(AppModel(preview: sample(status: .connected, mode: .selectedAppsAndBrowser))))
            }
        }
    }

    private enum ExtensionState {
        case notSetUp, active, updateNeeded
    }

    /// The browser extension as the next screen shows it; active unless the
    /// screen sets another state.
    @MainActor
    private static func extensionState(_ state: ExtensionState) {
        let installed = "0.4.1 (8be21f0)"
        let chrome = { (build: String) in
            BrowserExtension.Report(instance: "sample-chrome", browser: "Google Chrome", build: build, lastSeen: Date())
        }
        switch state {
        case .notSetUp:
            ExtensionMonitor.shared.showPreview(reports: [], expectedBuild: installed, isPrepared: false)
        case .active:
            ExtensionMonitor.shared.showPreview(reports: [chrome(installed)], expectedBuild: installed, isPrepared: true)
        case .updateNeeded:
            ExtensionMonitor.shared.showPreview(reports: [chrome("0.4.0 (3ca243a)")], expectedBuild: installed, isPrepared: true)
        }
    }

    @MainActor
    private static func window(_ model: AppModel) -> AnyView {
        AnyView(MainWindowView().environmentObject(model))
    }

    private static func sample(status: NEVPNStatus, mode: SharedConfig.RoutingMode,
                               list: AppModel.ListKind = .websites) -> AppModel.Preview {
        var preview = AppModel.Preview()
        preview.status = status
        preview.routingMode = mode
        preview.listKind = list
        preview.profiles = [
            ("gobritanya.ovpn", .init(displayName: "gobritanya", host: "172.104.229.229", protocolName: "OpenVPN UDP")),
            ("nyks-office.ovpn", .init(displayName: "nyks-office", host: "srv.nyks.net", protocolName: "OpenVPN TCP")),
        ]
        // Up to 40 installed apps, for real names and icons.
        let folders = ["/System/Applications", "/Applications"]
        let apps = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { folder + "/" + $0 }
        }
        preview.apps = apps.sorted().prefix(40).enumerated().compactMap { index, path in
            guard let identifier = Bundle(path: path)?.bundleIdentifier else { return nil }
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return (AppEntry(name: name, bundleIdentifier: identifier, signingIdentifier: identifier, path: path),
                    index % 7 != 3)
        }
        // 150 websites.
        let words = ["alpha", "beta", "cloud", "delta", "echo", "files", "git", "home", "intra", "jira",
                     "kube", "login", "mail", "news", "office", "panel", "queue", "reports", "status", "tickets"]
        let suffixes = ["com", "net", "io", "org", "dev", "co.uk", "com.tr"]
        var domains: [(String, Bool, Bool)] = [("icanhazip.com", true, true), ("ip-adresim.net", true, true),
                                              ("panel.galyata.com", false, false), ("srv.nyks.net", false, true)]
        var index = 0
        while domains.count < 150 {
            let name = words[index % words.count] + (index >= words.count ? "\(index / words.count)" : "")
            domains.append(("\(name).example-\(index % 9).\(suffixes[index % suffixes.count])", index % 3 == 0, index % 11 != 5))
            index += 1
        }
        preview.domains = domains.sorted { $0.0 < $1.0 }
        preview.diagnostics = .init(tunnelRegistered: true, vpnConfigSaved: true, perAppConfigSaved: true)
        return preview
    }

    @MainActor
    private static func render(into folder: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for screen in screens {
            for (suffix, appearance) in appearances {
                let url = folder.appendingPathComponent("\(screen.name)-\(suffix).png")
                extensionState(.active)
                save(screen.view(), width: screen.width, height: screen.height, appearance: appearance, to: url)
            }
        }
        print("Rendered \(screens.count * appearances.count) images into \(folder.path)")
    }

    @MainActor
    private static func save(_ view: AnyView, width: CGFloat, height: CGFloat?, appearance: NSAppearance.Name, to url: URL) {
        let root = view
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        // An offscreen window gives AppKit controls their real look; it is
        // never ordered onto the screen.
        let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        let size = NSSize(width: width, height: height ?? host.fittingSize.height)
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Draws its controls as in the frontmost window (accent colors), not
    /// greyed out as in a background one.
    private final class SnapshotWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }
}
#endif
