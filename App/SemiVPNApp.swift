import SwiftUI
import AppKit
import Combine
import NetworkExtension
import OpenVPNCore
import ServiceManagement
import UserNotifications

@main
struct SemiVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vpnManager = VPNManager()

    var body: some Scene {
        // `Window` (not `WindowGroup`) — exactly one window, Cmd+N is a no-op.
        Window("SemiVPN", id: "main") {
                ContentView()
                    .environmentObject(vpnManager)
                .frame(width: 1020, height: 720)
                .onAppear {
                    let url = URL(fileURLWithPath: "/tmp/semivpn-diag.log")
                    try? "scene onAppear pid=\(ProcessInfo.processInfo.processIdentifier)\n".write(to: url, atomically: true, encoding: .utf8)
                    NSApp.activate(ignoringOtherApps: true)
                    appDelegate.attach(vpnManager: vpnManager)
                    handleLaunchArguments()
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
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

/// Application lifecycle: menu-bar status item, close-to-tray behavior and
/// single-window management.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private static let launchAtLoginPreferenceKey = "launchAtLoginEnabled"

    private var statusItem: NSStatusItem?
    private weak var vpnManager: VPNManager?
    private var statusCancellable: AnyCancellable?
    private var previousStatus: NEVPNStatus?
    private var wasConnected = false
    private var trayActionBusy = false

    private var statusMenuItem: NSMenuItem?
    private var profileMenuItem: NSMenuItem?
    private var routingMenuItem: NSMenuItem?
    private var browserMenuItem: NSMenuItem?
    private var connectionActionMenuItem: NSMenuItem?
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
        synchronizeLaunchAtLogin()
        setupStatusItem()
        requestNotificationAuthorization()
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
        // Clear it again when the app becomes active so an already-running
        // instance also repairs the stale surface.
        clearStaleStatusNotifications(UNUserNotificationCenter.current())
        cleanupGhostMenuWindows()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // A tray menu is a separate, floating AppKit window. End tracking
        // explicitly when the app loses focus so a menu that is being
        // reconfigured during a VPN transition cannot remain over another
        // app as an invisible hit-testing surface.
        dismissStatusMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.cleanupGhostMenuWindows()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dismissStatusMenu()
    }

    var launchAtLoginEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.launchAtLoginPreferenceKey) as? Bool ?? true
    }

    var launchAtLoginStatusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "SemiVPN will open automatically when you sign in."
        case .requiresApproval:
            return "Approval is required in System Settings → General → Login Items."
        case .notRegistered:
            return "SemiVPN will not open automatically at login."
        case .notFound:
            return "SemiVPN is not available as a login item from this location."
        @unknown default:
            return "Login item status is unavailable."
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
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.launchAtLoginPreferenceKey) == nil {
            defaults.set(true, forKey: Self.launchAtLoginPreferenceKey)
        }
        guard launchAtLoginEnabled, SMAppService.mainApp.status != .enabled else { return }
        _ = setLaunchAtLogin(true)
    }

    func attach(vpnManager: VPNManager) {
        guard self.vpnManager !== vpnManager else {
            updateTrayMenu()
            return
        }

        self.vpnManager = vpnManager
        previousStatus = vpnManager.status
        wasConnected = vpnManager.status == .connected || vpnManager.status == .reasserting
        statusCancellable = vpnManager.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleStatusChange(status)
            }
        updateTrayMenu()
    }

    /// Closing the window hides it to the menu bar; the app keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock icon click (or the tray's "Show") reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWindow()
        }
        return true
    }

    /// Close button → hide to the tray: the window disappears and the app
    /// becomes a menu-bar-only app (no dock icon).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        mainWindow = sender
        dismissStatusMenu()
        cleanupGhostMenuWindows()
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("SemiVPN")
        }
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "VPN: Disconnected", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.image = menuImage("circle.fill")
        statusMenuItem = status
        menu.addItem(status)

        let profile = NSMenuItem(title: "Profile: None", action: nil, keyEquivalent: "")
        profile.submenu = NSMenu()
        profile.submenu?.delegate = self
        profile.image = menuImage("person.crop.circle")
        profileMenuItem = profile
        menu.addItem(profile)

        let routing = NSMenuItem(title: "Mode: Not configured", action: nil, keyEquivalent: "")
        routing.isEnabled = false
        routing.image = menuImage("arrow.left.arrow.right")
        routingMenuItem = routing
        menu.addItem(routing)

        let browser = NSMenuItem(title: "Browser domains: Off", action: nil, keyEquivalent: "")
        browser.isEnabled = false
        browser.image = menuImage("globe")
        browserMenuItem = browser
        menu.addItem(browser)

        menu.addItem(.separator())

        let connectionAction = NSMenuItem(title: "Connect", action: #selector(toggleConnectionAction), keyEquivalent: "")
        connectionAction.target = self
        connectionAction.image = menuImage("bolt.fill")
        connectionActionMenuItem = connectionAction
        menu.addItem(connectionAction)

        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show SemiVPN", action: #selector(showWindowAction), keyEquivalent: "")
        show.target = self
        show.image = menuImage("macwindow")
        menu.addItem(show)

        let quit = NSMenuItem(title: "Quit SemiVPN", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        quit.image = menuImage("power")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        updateTrayMenu()
    }

    private func updateTrayMenu() {
        guard let statusMenuItem,
              let profileMenuItem,
              let routingMenuItem,
              let browserMenuItem,
              let connectionActionMenuItem else { return }

        let currentStatus = vpnManager?.status ?? .invalid
        updateStatusItemIcon(currentStatus)
        statusMenuItem.title = "VPN: \(statusLabel(currentStatus))"
        statusMenuItem.image = menuImage(statusSymbol(currentStatus))
        statusMenuItem.attributedTitle = NSAttributedString(
            string: statusMenuItem.title,
            attributes: [.foregroundColor: statusColor(currentStatus)]
        )

        let savedSelection = SharedConfig.loadSelection()
        updateProfileSubmenu(selection: savedSelection, status: currentStatus)

        if let selection = savedSelection {
            profileMenuItem.title = "Profile: \(selection.profileName.replacingOccurrences(of: ".ovpn", with: ""))"
            profileMenuItem.image = menuImage("person.crop.circle")
            routingMenuItem.title = "Mode: \(selection.routingMode.title)"
            routingMenuItem.image = menuImage(selection.routingMode.icon)
            let domainConfiguration = SharedConfig.loadDomainConfiguration()
            let totalDomainCount = domainConfiguration.domains.count
            let activeDomainCount = domainConfiguration.activeDomains.count
            browserMenuItem.title = selection.routingMode.includesBrowser
                ? browserRoutingLabel(active: activeDomainCount, total: totalDomainCount)
                : "Browser routing: Not included in this mode"
            browserMenuItem.image = menuImage(selection.routingMode.includesBrowser ? "globe" : "globe.slash")
        } else {
            profileMenuItem.title = "Profile: None"
            profileMenuItem.image = menuImage("person.crop.circle")
            routingMenuItem.title = "Mode: Not configured"
            routingMenuItem.image = menuImage("arrow.left.arrow.right")
            browserMenuItem.title = "Browser domains: Off"
            browserMenuItem.image = menuImage("globe.slash")
        }

        if trayActionBusy {
            connectionActionMenuItem.title = currentStatus == .connected || currentStatus == .reasserting
                ? "Disconnecting…"
                : "Connecting…"
            connectionActionMenuItem.image = menuImage("arrow.triangle.2.circlepath")
            connectionActionMenuItem.isEnabled = false
        } else {
            switch currentStatus {
            case .connected, .reasserting:
                connectionActionMenuItem.title = "Disconnect"
                connectionActionMenuItem.image = menuImage("stop.circle.fill")
                connectionActionMenuItem.isEnabled = true
            case .connecting:
                connectionActionMenuItem.title = "Connecting…"
                connectionActionMenuItem.image = menuImage("arrow.triangle.2.circlepath")
                connectionActionMenuItem.isEnabled = false
            case .disconnecting:
                connectionActionMenuItem.title = "Disconnecting…"
                connectionActionMenuItem.image = menuImage("arrow.triangle.2.circlepath")
                connectionActionMenuItem.isEnabled = false
            default:
                connectionActionMenuItem.title = "Connect"
                connectionActionMenuItem.image = menuImage("bolt.fill")
                connectionActionMenuItem.isEnabled = vpnManager != nil && SharedConfig.loadSelection() != nil
            }
        }
    }

    private func menuImage(_ symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func updateStatusItemIcon(_ status: NEVPNStatus) {
        guard let button = statusItem?.button else { return }
        button.image = trayStatusImage(status)
        button.image?.isTemplate = true
        button.toolTip = "SemiVPN · \(statusLabel(status))"
        button.setAccessibilityValue(statusLabel(status))
    }

    private func trayStatusImage(_ status: NEVPNStatus) -> NSImage? {
        switch status {
        case .connected:
            return configuredTraySymbol("lock.shield.fill")
        case .connecting, .reasserting, .disconnecting:
            return composedTraySymbol(base: "lock.shield.fill", overlay: "arrow.triangle.2.circlepath")
        case .disconnected, .invalid:
            return configuredTraySymbol("lock.shield")
        @unknown default:
            return configuredTraySymbol("lock.shield")
        }
    }

    private func configuredTraySymbol(_ symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SemiVPN")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    /// Keeps the status item at the same size as the connected/disconnected
    /// shield while putting the refresh marker inside it. The previous
    /// version drew an 18-point shield onto a 16-point canvas, which clipped
    /// the silhouette and made the connecting state look oversized.
    private func composedTraySymbol(base: String, overlay: String) -> NSImage? {
        let canvasSize = NSSize(width: 16, height: 16)
        let canvas = NSImage(size: canvasSize)
        canvas.isTemplate = true

        let shieldConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let overlayConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
        guard let shield = NSImage(systemSymbolName: base, accessibilityDescription: nil)?
                .withSymbolConfiguration(shieldConfiguration),
              let overlayImage = NSImage(systemSymbolName: overlay, accessibilityDescription: nil)?
                .withSymbolConfiguration(overlayConfiguration) else {
            return configuredTraySymbol("shield")
        }

        canvas.lockFocus()
        shield.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16),
                    from: .zero, operation: .sourceOver, fraction: 1)
        overlayImage.draw(in: NSRect(x: 4.5, y: 4.5, width: 7, height: 7),
                          from: .zero, operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()
        return canvas
    }

    private func updateProfileSubmenu(selection: SharedConfig.Selection?, status: NEVPNStatus) {
        guard let submenu = profileMenuItem?.submenu else { return }
        submenu.removeAllItems()

        let profiles = SharedConfig.profileNames()
        if profiles.isEmpty {
            let empty = NSMenuItem(title: "No profiles imported", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        let canChange = !profileChangeLocked(status)
        for name in profiles {
            let item = NSMenuItem(
                title: name.replacingOccurrences(of: ".ovpn", with: ""),
                action: #selector(selectProfileAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = name
            item.state = name == selection?.profileName ? .on : .off
            item.image = menuImage(name == selection?.profileName ? "checkmark" : "doc.text")
            item.isEnabled = canChange
            submenu.addItem(item)
        }

        if !canChange {
            submenu.addItem(.separator())
            let locked = NSMenuItem(title: "Disconnect to change profile", action: nil, keyEquivalent: "")
            locked.isEnabled = false
            submenu.addItem(locked)
        }
    }

    private func profileChangeLocked(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting:
            return true
        default:
            return false
        }
    }

    private func statusSymbol(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reasserting: return "arrow.triangle.2.circlepath"
        case .disconnecting: return "arrow.triangle.2.circlepath"
        case .invalid: return "exclamationmark.circle"
        case .disconnected: return "circle.fill"
        @unknown default: return "questionmark.circle"
        }
    }

    private func statusColor(_ status: NEVPNStatus) -> NSColor {
        switch status {
        case .connected: return .systemGreen
        case .connecting, .reasserting, .disconnecting: return .systemOrange
        case .invalid: return .systemRed
        default: return .secondaryLabelColor
        }
    }

    private func browserRoutingLabel(active: Int, total: Int) -> String {
        guard total > 0 else { return "Browser routing: No domains configured" }
        if active == total {
            return "Browser routing: \(domainCountLabel(total)) active"
        }
        return "Browser routing: \(active) active · \(total - active) paused"
    }

    private func domainCountLabel(_ count: Int) -> String {
        "\(count) domain\(count == 1 ? "" : "s")"
    }

    private func statusLabel(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .reasserting: return "Reconnecting…"
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        @unknown default: return "Unknown"
        }
    }

    private func handleStatusChange(_ status: NEVPNStatus) {
        let oldStatus = previousStatus
        previousStatus = status
        // The status menu owns a separate top-right window. It must be gone
        // before its items are rewritten for the new connection state.
        dismissStatusMenu()
        updateTrayMenu()

        guard let oldStatus else { return }
        if status == .connected {
            if !wasConnected && oldStatus != .invalid {
                let connectionName = selectedConnectionName()
                postNotification(
                    title: "Connected",
                    body: connectionName + " is connected"
                )
            }
            wasConnected = true
        } else if status == .disconnected {
            if wasConnected {
                postNotification(
                    title: "Disconnected",
                    body: selectedConnectionName() + " is disconnected"
                )
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
            center.getNotificationSettings { settings in
                AppLogger.log(
                    "notifications: settings auth=\(settings.authorizationStatus.rawValue) " +
                    "alert=\(settings.alertSetting.rawValue) " +
                    "list=\(settings.notificationCenterSetting.rawValue) " +
                    "sound=\(settings.soundSetting.rawValue) " +
                    "style=\(settings.alertStyle.rawValue) " +
                    "scheduled=\(settings.scheduledDeliverySetting.rawValue)"
                )
            }
        }
    }

    private func clearStaleStatusNotifications(_ center: UNUserNotificationCenter) {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        AppLogger.log("notifications: cleared stale status notifications")
    }

    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized,
                  settings.alertSetting == .enabled else {
                AppLogger.log(
                    "notifications: blocked auth=\(settings.authorizationStatus.rawValue) " +
                    "alert=\(settings.alertSetting.rawValue) " +
                    "list=\(settings.notificationCenterSetting.rawValue)"
                )
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = "com.semivpn.status"
            if #available(macOS 12.0, *) {
                content.interruptionLevel = .active
            }

            let request = UNNotificationRequest(
                identifier: "com.semivpn.status.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            let requestIdentifier = request.identifier
            center.add(request) { error in
                if let error {
                    AppLogger.log("notifications: scheduling failed: \(error.localizedDescription)")
                } else {
                    AppLogger.log("notifications: scheduled \(title)")
                    // A successful add means macOS accepted the request; a
                    // delivered check tells us whether Notification Center
                    // actually received it. Foreground delivery is separately
                    // traced by userNotificationCenter(_:willPresent:...).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        center.getDeliveredNotifications { delivered in
                            let wasDelivered = delivered.contains {
                                $0.request.identifier == requestIdentifier
                            }
                            AppLogger.log(
                                "notifications: \(wasDelivered ? "delivered-to-center" : "accepted-not-delivered") \(title)"
                            )
                        }
                    }
                }
            }
        }
    }

    @objc private func selectProfileAction(_ sender: NSMenuItem) {
        dismissStatusMenu()
        guard let name = sender.representedObject as? String,
              let vpnManager,
              SharedConfig.profileNames().contains(name),
              !profileChangeLocked(vpnManager.status) else { return }

        let existing = SharedConfig.loadSelection()
        vpnManager.saveSelection(
            profileName: name,
            appIdentifiers: existing?.appIdentifiers ?? [],
            routingMode: existing?.routingMode ?? .allApps,
            appEntries: existing?.appEntries ?? []
        )
        AppLogger.log("tray selected profile: \(name)")
        updateTrayMenu()
    }

    @objc private func toggleConnectionAction() {
        // End menu tracking before changing the menu item title/enabled state
        // or starting an asynchronous VPN operation.
        dismissStatusMenu()
        guard let vpnManager, !trayActionBusy else {
            showWindow()
            return
        }

        if vpnManager.status == .connected || vpnManager.status == .reasserting {
            vpnManager.stop()
            return
        }

        trayActionBusy = true
        updateTrayMenu()
        Task { @MainActor [weak self] in
            do {
                try await vpnManager.start()
            } catch {
                AppLogger.log("tray connect failed: \(error.localizedDescription)")
                self?.showWindow()
            }
            self?.trayActionBusy = false
            self?.updateTrayMenu()
        }
    }

    @objc private func showWindowAction() {
        dismissStatusMenu()
        showWindow()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func showWindow() {
        dismissStatusMenu()
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
        return name.contains("StatusBar") ||
               name.contains("PopupMenu") ||
               name.contains("Panel") ||
               window is NSPanel
    }

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

    private func dismissStatusMenu() {
        // End tracking and ensure any lingering popup menu windows
        // are immediately ordered out so they cannot become an invisible
        // hit-testing obstacle under the menu bar.
        statusItem?.menu?.cancelTrackingWithoutAnimation()
        cleanupGhostMenuWindows()
        DispatchQueue.main.async { [weak self] in
            self?.cleanupGhostMenuWindows()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateTrayMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            self?.cleanupGhostMenuWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.cleanupGhostMenuWindows()
        }
    }
}

extension AppDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        AppLogger.log("notifications: willPresent \(notification.request.content.title)")
        // Keep connection updates as transient banners. Requesting `.list`
        // here also asks Notification Center to keep a foreground
        // notification in its list, which can leave a stale, hit-testing
        // surface behind after the banner is dismissed on macOS.
        completionHandler([.banner, .sound])
    }
}
