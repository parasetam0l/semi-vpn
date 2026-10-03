import Foundation

/// The SemiVPN browser extension: the copy the app installs for the
/// browser's "Load unpacked", and the reports of the browsers running it.
///
/// Every browser profile running the extension calls the control API about
/// once a minute and says which build it runs. SemiProxy records that here;
/// the app compares it with the build it installed.
public enum BrowserExtension {
    /// The extension ID, pinned by the `key` in its manifest. It is the same
    /// in Chrome and the other Chromium browsers.
    public static let id = "jaiknknmjmncnocbcbneepnefhokegma"
    public static let origin = "chrome-extension://\(id)"

    /// The folder browsers load the extension from, outside the app bundle so
    /// app updates do not move it. `SEMIVPN_EXTENSION_DIR` overrides it for
    /// tests.
    public static var installedDirectoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["SEMIVPN_EXTENSION_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SemiVPN", isDirectory: true)
            .appendingPathComponent("ChromeExtension", isDirectory: true)
    }

    /// The build of the extension in `directory`: the version_name an app
    /// build stamps from the extension's files ("0.4.0 (1a2b3c4)"), else the
    /// manifest version.
    public static func build(ofExtensionAt directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (manifest["version_name"] as? String) ?? (manifest["version"] as? String)
    }

    /// The version part of a build ("0.4.0" of "0.4.0 (1a2b3c4)").
    public static func version(ofBuild build: String) -> String {
        String(build.prefix { $0 != " " })
    }

    /// `build` as shown next to `other`: the version alone, or with its
    /// fingerprint when both share a version ("0.4.0 (3cb5d4e)").
    public static func display(_ build: String, comparedTo other: String?) -> String {
        guard let other, other != build, version(ofBuild: other) == version(ofBuild: build) else {
            return version(ofBuild: build)
        }
        return build
    }

    /// What one browser profile running the extension last reported.
    public struct Report: Codable, Equatable, Identifiable, Sendable {
        /// Random, generated once per browser profile.
        public var instance: String
        /// The browser's brand, e.g. "Google Chrome" or "Microsoft Edge".
        public var browser: String
        public var build: String
        public var lastSeen: Date

        public var id: String { instance }

        public init(instance: String, browser: String, build: String, lastSeen: Date) {
            self.instance = instance
            self.browser = browser
            self.build = build
            self.lastSeen = lastSeen
        }

        /// A report from request parameters, or nil when they are missing or
        /// implausible (the file must stay small whoever calls the API).
        public init?(instance: String?, browser: String?, build: String?, at date: Date) {
            func valid(_ value: String?) -> String? {
                guard let value = value?.trimmingCharacters(in: .whitespaces),
                      !value.isEmpty, value.count <= 64,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    return nil
                }
                return value
            }
            guard let instance = valid(instance), let browser = valid(browser), let build = valid(build) else {
                return nil
            }
            self.init(instance: instance, browser: browser, build: build, lastSeen: date)
        }
    }

    /// Posted (distributed) when a browser profile appears or changes build.
    public static let reportsDidChangeNotification = Notification.Name("com.semivpn.app.extensionReportsDidChange")

    public static let reportsFile = "extension_reports.json"
    public static var reportsURL: URL? {
        SharedConfig.containerURL?.appendingPathComponent(reportsFile)
    }

    /// Profiles not seen for this long are forgotten.
    static let reportRetention: TimeInterval = 30 * 24 * 3600
    static let maximumReports = 32

    public static func loadReports() -> [Report] {
        guard let url = reportsURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Report].self, from: data)) ?? []
    }

    /// Records a report. Returns true when the profile is new or changed
    /// build or browser, false when only its last-seen time moved.
    @discardableResult
    public static func record(_ report: Report) -> Bool {
        var reports = loadReports()
        reports.removeAll { report.lastSeen.timeIntervalSince($0.lastSeen) > reportRetention }
        guard let index = reports.firstIndex(where: { $0.instance == report.instance }) else {
            reports.append(report)
            if reports.count > maximumReports {
                reports = Array(reports.sorted { $0.lastSeen > $1.lastSeen }.prefix(maximumReports))
            }
            save(reports)
            return true
        }
        let previous = reports[index]
        let changed = previous.build != report.build || previous.browser != report.browser
        // Each profile reports about once a minute; keep the disk quiet.
        guard changed || report.lastSeen.timeIntervalSince(previous.lastSeen) >= 20 else { return false }
        reports[index] = report
        save(reports)
        return changed
    }

    /// Drops a profile, e.g. one whose extension was removed.
    public static func forget(instance: String) {
        save(loadReports().filter { $0.instance != instance })
    }

    private static func save(_ reports: [Report]) {
        guard let url = reportsURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(reports) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
