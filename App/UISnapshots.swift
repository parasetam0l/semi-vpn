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
        let view: @MainActor () -> AnyView
    }

    @MainActor
    private static var screens: [Screen] {
        [
            Screen(name: "window-connected-websites", width: 400) {
                window(AppModel(preview: sample(status: .connected, mode: .browserOnly)))
            },
            Screen(name: "window-apps-and-websites", width: 400) {
                window(AppModel(preview: sample(status: .disconnected, mode: .selectedAppsAndBrowser)))
            },
            Screen(name: "window-connecting-all-apps", width: 400) {
                window(AppModel(preview: sample(status: .connecting, mode: .allApps)))
            },
            Screen(name: "window-welcome", width: 400) {
                window(AppModel(preview: AppModel.Preview()))
            },
            Screen(name: "menubar-connected", width: 340) {
                AnyView(MainPanel(style: .menuBar)
                    .environmentObject(AppModel(preview: sample(status: .connected, mode: .browserOnly))))
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

    @MainActor
    private static func window(_ model: AppModel) -> AnyView {
        AnyView(MainPanel(style: .window).environmentObject(model))
    }

    private static func sample(status: NEVPNStatus, mode: SharedConfig.RoutingMode) -> AppModel.Preview {
        var preview = AppModel.Preview()
        preview.status = status
        preview.routingMode = mode
        preview.profiles = [
            ("gobritanya.ovpn", .init(displayName: "gobritanya", host: "172.104.229.229", protocolName: "OpenVPN UDP")),
            ("nyks-office.ovpn", .init(displayName: "nyks-office", host: "srv.nyks.net", protocolName: "OpenVPN TCP")),
        ]
        preview.apps = [
            (AppEntry(name: "Safari", bundleIdentifier: "com.apple.Safari", signingIdentifier: "com.apple.Safari",
                      path: "/Applications/Safari.app"), true),
            (AppEntry(name: "Mail", bundleIdentifier: "com.apple.mail", signingIdentifier: "com.apple.mail",
                      path: "/System/Applications/Mail.app"), true),
            (AppEntry(name: "Terminal", bundleIdentifier: "com.apple.Terminal", signingIdentifier: "com.apple.Terminal",
                      path: "/System/Applications/Utilities/Terminal.app"), false),
        ]
        preview.domains = [
            ("icanhazip.com", true, true),
            ("whatismyipaddress.com", true, true),
            ("srv.nyks.net", false, true),
            ("panel.galyata.com", false, false),
        ]
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
                save(screen.view(), width: screen.width, appearance: appearance, to: url)
            }
        }
        print("Rendered \(screens.count * appearances.count) images into \(folder.path)")
    }

    @MainActor
    private static func save(_ view: AnyView, width: CGFloat, appearance: NSAppearance.Name, to url: URL) {
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
        let size = host.fittingSize
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
