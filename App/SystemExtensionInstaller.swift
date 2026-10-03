import AppKit
import Foundation
import SystemExtensions

/// Activates the tunnel provider, a Network Extension system extension
/// embedded in the app (Contents/Library/SystemExtensions), and tracks its
/// state.
///
/// macOS installs a system extension only for an app in /Applications, and
/// the first time only after the user allows it in System Settings. An app
/// update brings a new build of the extension; activating again replaces the
/// running one. The request is submitted at every launch, which is cheap
/// when the extension is already active.
@MainActor
final class SystemExtensionInstaller: NSObject, ObservableObject {
    static let shared = SystemExtensionInstaller()
    static let identifier = "com.semivpn.app.TunnelProvider"

    enum State: Equatable {
        case unknown
        case activating
        /// Waiting for the user to allow it in System Settings.
        case needsApproval
        case active
        case willCompleteAfterReboot
        case failed(String)
    }

    @Published private(set) var state: State = .unknown
    private var waiters: [CheckedContinuation<Void, Error>] = []

    enum ActivationError: LocalizedError {
        case needsApproval
        case willCompleteAfterReboot
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .needsApproval:
                return "Allow SemiVPN’s network extension in System Settings → General → Login Items & Extensions → Network Extensions, then connect again."
            case .willCompleteAfterReboot:
                return "SemiVPN’s network extension is installed after the Mac restarts."
            case .failed(let message):
                return "SemiVPN’s network extension could not be installed: \(message)"
            }
        }
    }

    func activate() {
        guard state != .activating else { return }
        state = .activating
        AppLogger.log("system extension: requesting activation of \(Self.identifier)")
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Returns once the extension is active, activating it when needed;
    /// throws when it waits for the user's approval or failed.
    func ensureActive() async throws {
        switch state {
        case .active:
            return
        case .needsApproval:
            throw ActivationError.needsApproval
        case .willCompleteAfterReboot:
            throw ActivationError.willCompleteAfterReboot
        case .unknown, .failed:
            activate()
        case .activating:
            break
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(continuation)
        }
    }

    /// System Settings → General → Login Items & Extensions.
    static func openApprovalSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func settle(_ newState: State) {
        state = newState
        let waiters = self.waiters
        switch newState {
        case .active:
            self.waiters.removeAll()
            waiters.forEach { $0.resume() }
        case .needsApproval:
            // Keep waiting: the request completes once the user allows it,
            // but a connect attempt should say what to do now.
            self.waiters.removeAll()
            waiters.forEach { $0.resume(throwing: ActivationError.needsApproval) }
        case .willCompleteAfterReboot:
            self.waiters.removeAll()
            waiters.forEach { $0.resume(throwing: ActivationError.willCompleteAfterReboot) }
        case .failed(let message):
            self.waiters.removeAll()
            waiters.forEach { $0.resume(throwing: ActivationError.failed(message)) }
        case .unknown, .activating:
            break
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == OSSystemExtensionErrorDomain,
              let code = OSSystemExtensionError.Code(rawValue: nsError.code) else {
            return nsError.localizedDescription
        }
        switch code {
        case .unsupportedParentBundleLocation:
            return "SemiVPN must be in the Applications folder."
        case .extensionNotFound:
            return "the extension is missing from the app."
        case .codeSignatureInvalid:
            return "its code signature is invalid."
        case .validationFailed:
            return "macOS rejected it (\(nsError.localizedDescription))."
        case .requestCanceled, .requestSuperseded:
            return "the request was cancelled."
        default:
            return nsError.localizedDescription
        }
    }
}

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        AppLogger.log("system extension: replacing \(existing.bundleVersion) with \(replacement.bundleVersion)")
        // The request's queue is the main queue; this runs well before
        // macOS stops the tunnel for the swap.
        Task { @MainActor in AppModel.shared.vpn.extensionWillBeReplaced() }
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        AppLogger.log("system extension: waiting for the user's approval in System Settings")
        Task { @MainActor in self.settle(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        AppLogger.log("system extension: activation finished (\(result == .completed ? "active" : "after reboot"))")
        Task { @MainActor in
            self.settle(result == .completed ? .active : .willCompleteAfterReboot)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = Self.describe(error)
        AppLogger.log("system extension: activation failed: \(error)")
        Task { @MainActor in self.settle(.failed(message)) }
    }
}

import SwiftUI

/// Shown while the tunnel's system extension waits for the user's approval,
/// needs a restart, or could not be installed.
struct SystemExtensionBanner: View {
    @ObservedObject var installer: SystemExtensionInstaller

    var body: some View {
        switch installer.state {
        case .needsApproval:
            NoticeCard(icon: "lock.shield", tint: SemiTheme.amber,
                       title: "Allow SemiVPN’s network extension",
                       detail: "macOS needs your permission once. In System Settings → General → Login Items & Extensions → Network Extensions, turn on SemiVPN.") {
                Button("Open System Settings") { SystemExtensionInstaller.openApprovalSettings() }
                    .buttonStyle(.borderedProminent)
            }
        case .willCompleteAfterReboot:
            NoticeCard(icon: "arrow.clockwise.circle", tint: SemiTheme.amber,
                       title: "Restart to finish installing",
                       detail: "SemiVPN’s network extension is ready after the Mac restarts.") {
                EmptyView()
            }
        case .failed(let message):
            NoticeCard(icon: "exclamationmark.triangle.fill", tint: .red,
                       title: "The network extension couldn’t be installed",
                       detail: message) {
                Button("Try Again") { installer.activate() }
                    .buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }
}
