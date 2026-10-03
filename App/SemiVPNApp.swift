import SwiftUI
import AppKit
import Combine
import NetworkExtension
import OpenVPNCore
import ServiceManagement
import UserNotifications

@main
enum SemiVPNMain {
    static func main() {
        #if DEBUG
        // `--render-ui <folder>`: draws the screens with sample data and
        // exits (Scripts/ui-snapshots.sh).
        UISnapshots.runIfRequested()
        #endif
        SemiVPNApp.main()
    }
}

struct SemiVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // `Window` (not `WindowGroup`): exactly one window, ⌘N does nothing.
        Window("SemiVPN", id: "main") {
            MainWindowView()
                .environmentObject(model)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    handleLaunchArguments()
                }
        }
        .defaultSize(width: 400, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",")
            }
        }
    }

    /// Headless test path: `semi-vpn --connect <profile-name>` connects
    /// without touching the UI. The profile must already be imported.
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--connect"), index + 1 < args.count else { return }
        let profileName = args[index + 1]
        guard SharedConfig.profileNames().contains(profileName) else {
            print("semi-vpn: profile not found: \(profileName)")
            return
        }
        let vpnManager = model.vpn
        Task {
            // Preserve the per-app selection from the UI if one exists.
            let existing = SharedConfig.loadSelection()
            vpnManager.saveSelection(
                profileName: profileName,
                appIdentifiers: existing?.appIdentifiers ?? [],
                fullTunnel: existing?.fullTunnel ?? false,
                appEntries: existing?.appEntries ?? [],
                domainRouting: existing?.domainRouting ?? false
            )
            do {
                try await vpnManager.start()
                print("semi-vpn: connecting to \(profileName)")
            } catch {
                print("semi-vpn: start failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Application lifecycle: the menu bar item, hiding to the menu bar when
/// the window closes, the login item, and connection notifications.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    /// The app's delegate. SwiftUI's delegate adaptor installs its own object
    /// as NSApp.delegate, so `NSApp.delegate as? AppDelegate` is always nil.
    private(set) static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    private static let launchAtLoginPreferenceKey = "launchAtLoginEnabled"

    private var menuBar: MenuBarController?
    private var statusCancellable: AnyCancellable?
    private var previousStatus: NEVPNStatus?
    private var wasConnected = false
    private weak var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apple requires the notification delegate to be installed before
        // launch completes so foreground delivery is routed through
        // userNotificationCenter(_:willPresent:completionHandler:).
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        clearStaleStatusNotifications(center)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.log("app launched")
        synchronizeLaunchAtLogin()
        let model = AppModel.shared
        menuBar = MenuBarController(model: model)
        observeStatus(of: model.vpn)
        requestNotificationAuthorization()
        ExtensionMonitor.shared.start()
        // Installs the tunnel's system extension, or replaces it after an
        // app update (a no-op when that build is already active).
        SystemExtensionInstaller.shared.activate()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let window = self.findMainWindow() {
                self.mainWindow = window
                window.delegate = self
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Older builds could leave a delivered status notification behind as
        // a transparent hit-testing surface after its banner disappeared.
        clearStaleStatusNotifications(UNUserNotificationCenter.current())
        cleanupGhostMenuWindows()
    }

    func applicationDidResignActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.cleanupGhostMenuWindows()
        }
    }

    /// Opt-in: the app no longer registers itself as a login item on first
    /// launch; an earlier explicit choice is kept.
    var launchAtLoginEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.launchAtLoginPreferenceKey) as? Bool ?? false
    }

    var launchAtLoginStatusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "SemiVPN opens when you log in and keeps running in the menu bar."
        case .requiresApproval:
            return "Allow SemiVPN in System Settings → General → Login Items."
        case .notRegistered:
            return "SemiVPN keeps running in the menu bar when you close its window."
        case .notFound:
            return "SemiVPN can’t be a login item from this location. Move it to Applications."
        @unknown default:
            return "The login item status is unavailable."
        }
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginPreferenceKey)
            AppLogger.log("launch at login \(enabled ? "enabled" : "disabled")")
            return .success(())
        } catch {
            AppLogger.log("launch at login update failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private func synchronizeLaunchAtLogin() {
        guard launchAtLoginEnabled, SMAppService.mainApp.status != .enabled else { return }
        _ = setLaunchAtLogin(true)
    }

    private func observeStatus(of vpnManager: VPNManager) {
        previousStatus = vpnManager.status
        wasConnected = vpnManager.status == .connected || vpnManager.status == .reasserting
        statusCancellable = vpnManager.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleStatusChange(status)
            }
    }

    /// Closing the window hides it to the menu bar; the app keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock icon click reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWindow()
        }
        return true
    }

    /// Close button → hide to the menu bar: the window disappears and the
    /// app becomes a menu-bar-only app (no Dock icon).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        mainWindow = sender
        cleanupGhostMenuWindows()
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func showWindow() {
        cleanupGhostMenuWindows()
        NSApp.setActivationPolicy(.regular)
        if let window = findMainWindow() {
            mainWindow = window
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func findMainWindow() -> NSWindow? {
        if let mainWindow { return mainWindow }
        return NSApp.windows.first { window in
            window.identifier?.rawValue == "main" ||
            (window.level == .normal && !isAuxiliaryWindow(window))
        }
    }

    private func isAuxiliaryWindow(_ window: NSWindow) -> Bool {
        let name = String(describing: type(of: window))
        return window.identifier?.rawValue == "settings" ||
               name.contains("StatusBar") ||
               name.contains("PopupMenu") ||
               name.contains("Popover") ||
               name.contains("Panel") ||
               window is NSPanel
    }

    /// A popup menu window can outlive its menu as an invisible surface
    /// that swallows clicks; order such leftovers out.
    private func cleanupGhostMenuWindows() {
        for window in NSApp.windows {
            let name = String(describing: type(of: window))
            if name.contains("PopupMenu") {
                if window.alphaValue == 0 || !window.isVisible || (window.contentView?.subviews.isEmpty ?? false) {
                    window.orderOut(nil)
                }
            }
        }
    }

    // MARK: - Notifications

    private func handleStatusChange(_ status: NEVPNStatus) {
        let oldStatus = previousStatus
        previousStatus = status
        guard let oldStatus else { return }
        if status == .connected {
            if !wasConnected && oldStatus != .invalid {
                postNotification(title: "Connected", body: selectedConnectionName() + " is connected")
            }
            wasConnected = true
        } else if status == .disconnected {
            if wasConnected {
                postNotification(title: "Disconnected", body: selectedConnectionName() + " is disconnected")
            }
            wasConnected = false
        }
    }

    private func selectedConnectionName() -> String {
        let selection = SharedConfig.loadSelection()
        let profileName = selection?.profileName
            .replacingOccurrences(of: ".ovpn", with: "") ?? "your selected profile"
        let serverAddress = selection
            .flatMap { SharedConfig.loadProfile(name: $0.profileName) }
            .flatMap { try? OVPNParser().parse($0) }
            .flatMap { $0.remotes.first?.host } ?? "VPN"
        return "\(serverAddress) [\(profileName)]"
    }

    private func requestNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLogger.log("notifications: authorization failed: \(error.localizedDescription)")
                return
            }
            AppLogger.log("notifications: authorization \(granted ? "granted" : "denied")")
        }
    }

    private func clearStaleStatusNotifications(_ center: UNUserNotificationCenter) {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized,
                  settings.alertSetting == .enabled else {
                AppLogger.log("notifications: blocked auth=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = "com.semivpn.status"
            content.interruptionLevel = .active
            let request = UNNotificationRequest(
                identifier: "com.semivpn.status.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    AppLogger.log("notifications: scheduling failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Keep connection updates as transient banners. Requesting `.list`
        // here also asks Notification Center to keep a foreground
        // notification in its list, which can leave a stale, hit-testing
        // surface behind after the banner is dismissed on macOS.
        completionHandler([.banner, .sound])
    }
}
