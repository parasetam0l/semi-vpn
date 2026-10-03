import Foundation
import SwiftUI

/// Clears macOS's per-app VPN app cache and restarts its VPN service
/// (nesessionmanager), with the user's administrator password.
///
/// Network Extension resolves each per-app rule to the executables it
/// matches once per signing identifier and stores that in a cache file that
/// survives restarts. After an update that changes SemiProxy's executable,
/// the rule can keep matching the old one, and browser traffic leaves
/// outside the VPN. The service is frozen, the cache file removed, and the
/// service killed so it cannot write its copy back; launchd starts it again
/// at once and it rebuilds the cache. Every VPN on the Mac disconnects
/// briefly.
enum VPNRoutingRepair {
    static let cacheFile = "/Library/Preferences/com.apple.networkextension.uuidcache.plist"

    enum Failure: Error, Equatable {
        case cancelled
        case failed(String)
    }

    static func restartVPNService(completion: @escaping (Result<Void, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            do shell script "/usr/bin/killall -STOP nesessionmanager; /bin/rm -f \(cacheFile); \
            /usr/bin/killall -KILL nesessionmanager" with prompt "SemiVPN wants to clear the macOS VPN app cache \
            and restart the VPN service so that browser traffic uses the VPN again. All VPN connections \
            disconnect briefly." with administrator privileges
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            let result: Result<Void, Failure>
            do {
                try process.run()
                let output = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    result = .success(())
                } else if output.contains("-128") {
                    result = .failure(.cancelled)   // the user cancelled the password prompt
                } else {
                    result = .failure(.failed(output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } catch {
                result = .failure(.failed(error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

enum RoutingRepairPhase: Equatable {
    case idle
    case restartingService
    case reconnecting
    /// Reconnected; waiting for SemiProxy to confirm it now uses the VPN.
    case verifying
    case failed(String)
    /// The restart did not help.
    case stillBroken

    var isBusy: Bool {
        self == .restartingService || self == .reconnecting || self == .verifying
    }
}

/// Shown above the footer while the VPN is connected but macOS routes
/// SemiVPN's browser proxy outside it.
struct RoutingRepairBanner: View {
    let blocksListedSites: Bool
    let phase: RoutingRepairPhase
    let onRepair: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.red.opacity(0.9))
            VStack(alignment: .leading, spacing: 4) {
                Text("Browser traffic is not using the VPN")
                    .font(.system(size: 13, weight: .semibold))
                Text(blocksListedSites
                     ? "macOS is not routing SemiVPN’s browser proxy through the VPN, so listed sites are blocked."
                     : "macOS is not routing SemiVPN’s browser proxy through the VPN, so listed sites use your regular connection.")
                    .font(.system(size: 11))
                Text("macOS still matches the routing rule against an older copy of SemiVPN’s proxy. Repairing clears that record and restarts the macOS VPN service: it asks for your administrator password and briefly disconnects all VPNs.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SemiTheme.textMuted)
                if let note = note {
                    Text(note)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(noteColor)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(action: onRepair) {
                HStack(spacing: 6) {
                    if phase.isBusy { ProgressView().controlSize(.small) }
                    Text(buttonTitle)
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(phase.isBusy)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.12))
    }

    private var buttonTitle: String {
        switch phase {
        case .restartingService: return "Restarting…"
        case .reconnecting: return "Reconnecting…"
        case .verifying: return "Checking…"
        default: return "Repair VPN Routing…"
        }
    }

    private var note: String? {
        switch phase {
        case .failed(let message): return "The VPN service could not be restarted: \(message)"
        case .stillBroken: return "Still not routed through the VPN after the repair. As a workaround, use the All apps routing mode."
        default: return nil
        }
    }

    private var noteColor: Color {
        if case .failed = phase { return .red }
        return SemiTheme.amber
    }
}
