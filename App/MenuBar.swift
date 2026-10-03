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
            .sink { [weak self] status in self?.updateIcon(status) }
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
        ExtensionMonitor.shared.refresh()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Take key focus so the panel's controls respond at once and it
        // closes when the user clicks elsewhere.
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Icon

    private func updateIcon(_ status: NEVPNStatus) {
        guard let button = statusItem.button else { return }
        button.image = Self.image(for: status)
        button.image?.isTemplate = true
        let label = Self.label(for: status)
        button.toolTip = "SemiVPN · \(label)"
        button.setAccessibilityValue(label)
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

    private static func image(for status: NEVPNStatus) -> NSImage? {
        switch status {
        case .connected:
            return symbol("lock.shield.fill")
        case .connecting, .reasserting, .disconnecting:
            return composed(base: "lock.shield.fill", overlay: "arrow.triangle.2.circlepath")
        default:
            return symbol("lock.shield")
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "SemiVPN")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    /// The shield at the same size as the other states, with a small
    /// arrows mark inside it.
    private static func composed(base: String, overlay: String) -> NSImage? {
        let shieldConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let overlayConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
        guard let shield = NSImage(systemSymbolName: base, accessibilityDescription: nil)?
                .withSymbolConfiguration(shieldConfiguration),
              let mark = NSImage(systemSymbolName: overlay, accessibilityDescription: nil)?
                .withSymbolConfiguration(overlayConfiguration) else {
            return symbol("shield")
        }
        let canvas = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            shield.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16),
                        from: .zero, operation: .sourceOver, fraction: 1)
            mark.draw(in: NSRect(x: 4.5, y: 4.5, width: 7, height: 7),
                      from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        canvas.isTemplate = true
        return canvas
    }
}
