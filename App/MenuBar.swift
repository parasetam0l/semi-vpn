import AppKit
import Combine
import NetworkExtension
import SwiftUI

/// The menu bar item: a shield that shows the connection state, and a panel
/// with the main controls when clicked.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private(set) static weak var shared: MenuBarController?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var statusCancellable: AnyCancellable?
    private var reconnectingCancellable: AnyCancellable?
    /// Plays MenuBarIcon.connectingFrames while the connection changes.
    private var animationTimer: Timer?
    private var animationFrame = 0

    init(model: AppModel) {
        self.model = model
        super.init()
        MenuBarController.shared = self

        let host = NSHostingController(rootView: MenuBarPanel().environmentObject(model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("SemiVPN")
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusCancellable = model.vpn.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateIcon(status)
                self?.recheckAddresses(after: status)
            }
        // A restart after an update reconnects while the status reads
        // disconnected.
        reconnectingCancellable = model.vpn.$isReconnecting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIcon(self.model.vpn.status)
            }
        updateIcon(model.vpn.status)
    }

    func close() {
        popover.performClose(nil)
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        model.refresh()
        #if DEBUG
        // The preview shows a sample extension state; refreshing would
        // read the scratch folder's.
        if !UISnapshots.isPreviewing { ExtensionMonitor.shared.refresh() }
        #else
        ExtensionMonitor.shared.refresh()
        #endif
        IPAddressChecker.shared.refresh(vpnConnected: model.vpn.status == .connected)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Take key focus so the panel's controls respond at once and it
        // closes when the user clicks elsewhere.
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Connecting or disconnecting from the open panel changes the address
    /// with the VPN: check again.
    private func recheckAddresses(after status: NEVPNStatus) {
        guard popover.isShown, status == .connected || status == .disconnected else { return }
        IPAddressChecker.shared.refresh(vpnConnected: status == .connected)
    }

    // MARK: - Icon

    private func updateIcon(_ status: NEVPNStatus) {
        guard let button = statusItem.button else { return }
        let changing = [.connecting, .reasserting, .disconnecting].contains(status) || model.vpn.isReconnecting
        if changing {
            startAnimating()
        } else {
            stopAnimating()
            button.image = status == .connected ? MenuBarIcon.connected : MenuBarIcon.notConnected
        }
        let label = model.vpn.isReconnecting ? "Reconnecting" : Self.label(for: status)
        button.toolTip = "SemiVPN · \(label)"
        button.setAccessibilityValue(label)
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationFrame = 0
        statusItem.button?.image = MenuBarIcon.connectingFrames[0]
        let timer = Timer(timeInterval: MenuBarIcon.frameDuration, repeats: true) { [weak self] _ in
            // The main run loop fires it on the main thread. Showing the
            // frame later, in a Task, could put it over the final icon
            // when the timer fired just before it stopped.
            MainActor.assumeIsolated { self?.showNextFrame() }
        }
        // Common modes: it keeps moving while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func showNextFrame() {
        let frames = MenuBarIcon.connectingFrames
        animationFrame = (animationFrame + 1) % frames.count
        statusItem.button?.image = frames[animationFrame]
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private static func label(for status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .reasserting: return "Reconnecting"
        default: return "Not connected"
        }
    }
}
