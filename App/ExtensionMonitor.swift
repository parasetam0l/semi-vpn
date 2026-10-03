import AppKit
import Foundation

/// Tracks the browser profiles running the SemiVPN extension and whether they
/// run the build this app installed.
///
/// The app copies each new build into the extension folder, but a browser
/// runs it only after the user clicks Reload on its Extensions page (an
/// unpacked extension cannot reload its own files). A profile on an old
/// build is shown as needing that update in the Browser tab, and the user is
/// notified once per build.
///
/// It also watches whether the browser traffic really uses the VPN: SemiProxy
/// reports when macOS routes it outside the tunnel (see
/// SharedConfig.ProxyHealth), which the window offers to repair.
@MainActor
final class ExtensionMonitor: ObservableObject {
    static let shared = ExtensionMonitor()

    enum Status: Equatable {
        /// Runs the installed build.
        case upToDate
        /// Runs an older build: the user has to reload it.
        case updateNeeded
        /// Ran an older build when it last reported (the browser is closed
        /// or the extension is off).
        case outdatedIdle
    }

    struct Profile: Identifiable, Equatable {
        let report: BrowserExtension.Report
        /// "Google Chrome", or "Google Chrome · profile 2" when one browser
        /// has several profiles with the extension.
        let label: String
        let status: Status
        /// Reported within the last few minutes.
        let isActive: Bool

        var id: String { report.instance }
        var version: String { BrowserExtension.version(ofBuild: report.build) }
        var browser: ChromiumBrowser? { ChromiumBrowser.installed(named: report.browser) }
    }

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var isPrepared = false
    /// The build this app ships and installs into the extension folder.
    @Published private(set) var expectedBuild: String?
    /// The VPN is connected for the browser, but macOS routes SemiProxy
    /// outside it, so listed sites are blocked or go direct.
    @Published private(set) var browserRoutingBroken = false
    /// Whether listed sites are blocked (fail-closed) rather than direct
    /// while the VPN is unavailable to them.
    @Published private(set) var blocksListedSites = false

    var expectedVersion: String? { expectedBuild.map(BrowserExtension.version(ofBuild:)) }
    var profilesNeedingUpdate: [Profile] { profiles.filter { $0.status == .updateNeeded } }

    /// Profiles report about once a minute.
    static let activeWindow: TimeInterval = 150

    private var timer: Timer?
    private static let notifiedKey = "notifiedExtensionUpdates"

    func start() {
        guard timer == nil else { return }
        // Install a new build before the browsers' next check-in, also when
        // the app runs in the menu bar without its window.
        ChromeExtensionInstaller.syncInstalledExtensionIfNeeded()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in ExtensionMonitor.shared.refresh() }
        }
        for name in [BrowserExtension.reportsDidChangeNotification, SharedConfig.proxyHealthDidChangeNotification] {
            DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in ExtensionMonitor.shared.refresh() }
            }
        }
    }

    func refresh(now: Date = Date()) {
        let prepared = ChromeExtensionInstaller.isPrepared
        if prepared != isPrepared { isPrepared = prepared }
        let expected = ChromeExtensionInstaller.bundledBuild
        if expected != expectedBuild { expectedBuild = expected }

        // Number a browser's profiles in a stable order.
        let reports = BrowserExtension.loadReports().sorted { $0.instance < $1.instance }
        let profileCounts = Dictionary(grouping: reports, by: \.browser).mapValues(\.count)
        var numbers: [String: Int] = [:]
        var next: [Profile] = []
        for report in reports {
            let number = (numbers[report.browser] ?? 0) + 1
            numbers[report.browser] = number
            let label = (profileCounts[report.browser] ?? 0) > 1 ? "\(report.browser) · profile \(number)" : report.browser
            let isActive = now.timeIntervalSince(report.lastSeen) < Self.activeWindow
            next.append(Profile(
                report: report,
                label: label,
                status: status(of: report, isActive: isActive),
                isActive: isActive
            ))
        }
        next.sort { ($0.isActive ? 0 : 1, $0.label) < ($1.isActive ? 0 : 1, $1.label) }
        if next != profiles { profiles = next }
        notifyAboutNewUpdateNeeds()
        refreshRoutingHealth()
    }

    private func refreshRoutingHealth() {
        let blocks = SharedConfig.loadDomainConfiguration().blockWhenDisconnected
        if blocks != blocksListedSites { blocksListedSites = blocks }
        let broken = SharedConfig.loadProxyHealth()?.tunnelBypassed == true
            && SharedConfig.loadRuntimeState().forwardingAllowed
        guard broken != browserRoutingBroken else { return }
        browserRoutingBroken = broken
        guard broken else {
            AppLogger.log("routing: browser traffic uses the VPN again")
            return
        }
        AppLogger.log("routing: macOS routes SemiProxy outside the VPN")
        AppDelegate.shared?.postNotification(
            title: "Browser traffic is not using the VPN",
            body: (blocks ? "Listed sites are blocked: " : "Listed sites use your regular connection: ")
                + "macOS stopped routing SemiVPN’s browser proxy through the VPN. Open SemiVPN and choose Repair VPN Routing."
        )
    }

    private func status(of report: BrowserExtension.Report, isActive: Bool) -> Status {
        guard let expected = expectedBuild, report.build != expected else { return .upToDate }
        return isActive ? .updateNeeded : .outdatedIdle
    }

    private func notifyAboutNewUpdateNeeds() {
        guard let expected = expectedBuild else { return }
        var notified = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? [])
        let pending = profilesNeedingUpdate.filter { !notified.contains($0.id + "|" + expected) }
        guard !pending.isEmpty else { return }
        if notified.count > 200 { notified.removeAll() }
        for profile in pending {
            notified.insert(profile.id + "|" + expected)
            AppDelegate.shared?.postNotification(
                title: "Update the SemiVPN extension in \(profile.report.browser)",
                body: "\(profile.label) still runs extension \(profile.version). Open its Extensions page and click "
                    + "the reload button on “SemiVPN Domain Routing”. SemiVPN’s Browser tab shows the steps."
            )
            AppLogger.log("extension: \(profile.label) needs a manual update (\(profile.report.build) -> \(expected))")
        }
        UserDefaults.standard.set(Array(notified), forKey: Self.notifiedKey)
    }
}
