import AppKit
import Combine
import Sparkle

/// Updates from GitHub Releases with Sparkle. The feed (SUFeedURL) is the
/// appcast.xml attached to the latest published release; each update is
/// signed with the EdDSA key whose public half is SUPublicEDKey, and must
/// carry the same Developer ID signature as the running app. SemiVPN checks
/// once a day and always asks before installing (SUAllowsAutomaticUpdates
/// is off). Development builds don't check: they aren't releases.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// Nil in development builds.
    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheck: Date?
    private var cancellables: Set<AnyCancellable> = []

    var isAvailable: Bool { controller != nil }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    private init() {
        #if DEBUG
        controller = nil
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
        if let updater = controller?.updater {
            updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }
                .store(in: &cancellables)
            updater.publisher(for: \.lastUpdateCheckDate)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.lastCheck = $0 }
                .store(in: &cancellables)
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// "1.2.0 (1791023807)"
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
