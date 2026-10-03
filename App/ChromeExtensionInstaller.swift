import AppKit
import Foundation

/// A Chromium browser the SemiVPN extension can be loaded into. The pinned
/// extension ID is the same in all of them.
struct ChromiumBrowser: Identifiable, Hashable {
    let name: String
    let bundleIdentifier: String
    /// The browser's extensions page, typed into its address bar.
    let extensionsPage: String

    var id: String { bundleIdentifier }

    static let known: [ChromiumBrowser] = [
        ChromiumBrowser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", extensionsPage: "chrome://extensions"),
        ChromiumBrowser(name: "Google Chrome Beta", bundleIdentifier: "com.google.Chrome.beta", extensionsPage: "chrome://extensions"),
        ChromiumBrowser(name: "Google Chrome Dev", bundleIdentifier: "com.google.Chrome.dev", extensionsPage: "chrome://extensions"),
        ChromiumBrowser(name: "Google Chrome Canary", bundleIdentifier: "com.google.Chrome.canary", extensionsPage: "chrome://extensions"),
        ChromiumBrowser(name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", extensionsPage: "edge://extensions"),
        ChromiumBrowser(name: "Brave", bundleIdentifier: "com.brave.Browser", extensionsPage: "brave://extensions"),
        ChromiumBrowser(name: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi", extensionsPage: "vivaldi://extensions"),
        ChromiumBrowser(name: "Opera", bundleIdentifier: "com.operasoftware.Opera", extensionsPage: "opera://extensions"),
        ChromiumBrowser(name: "Arc", bundleIdentifier: "company.thebrowser.Browser", extensionsPage: "arc://extensions"),
        ChromiumBrowser(name: "Chromium", bundleIdentifier: "org.chromium.Chromium", extensionsPage: "chrome://extensions"),
    ]

    /// The browser's details page for the SemiVPN extension, with its
    /// Reload button.
    var extensionDetailsPage: String {
        "\(extensionsPage)/?id=\(BrowserExtension.id)"
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// The known browsers installed on this Mac, Chrome first.
    static var installed: [ChromiumBrowser] {
        known.filter { $0.applicationURL != nil }
    }

    /// The installed browser a report's brand name belongs to.
    static func installed(named name: String) -> ChromiumBrowser? {
        installed.first { $0.name == name }
    }
}

/// Prepares the bundled extension for the browsers' one-time "Load unpacked"
/// flow. Chrome on macOS does not let a regular app install an extension, so
/// the extension is copied to a stable folder that survives app updates; the
/// extension reloads itself from there when the app installs a new build.
enum ChromeExtensionInstaller {
    static let extensionDirectoryName = "ChromeExtension"

    static var installedDirectoryURL: URL {
        BrowserExtension.installedDirectoryURL
    }

    static var bundledDirectoryURL: URL? {
        Bundle.main.url(forResource: extensionDirectoryName, withExtension: nil)
    }

    /// The build this app ships ("0.4.0 (1a2b3c4)").
    static var bundledBuild: String? {
        bundledDirectoryURL.flatMap(BrowserExtension.build(ofExtensionAt:))
    }

    static var isPrepared: Bool {
        FileManager.default.fileExists(
            atPath: installedDirectoryURL.appendingPathComponent("manifest.json").path
        )
    }

    /// Checks whether the installed extension differs from the bundled extension and updates it automatically.
    @discardableResult
    static func syncInstalledExtensionIfNeeded() -> Bool {
        guard isPrepared, let bundledDirectoryURL else {
            return false
        }

        if isInstalledExtensionOutdated(bundledURL: bundledDirectoryURL, installedURL: installedDirectoryURL) {
            do {
                try prepare()
                AppLogger.log("Chrome extension automatically updated to match bundled version.")
                return true
            } catch {
                AppLogger.log("Failed to auto-update Chrome extension: \(error)")
                return false
            }
        }
        return false
    }

    private static func isInstalledExtensionOutdated(bundledURL: URL, installedURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard let bundledEnumerator = fileManager.enumerator(
            at: bundledURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let fileURL as URL in bundledEnumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }
            let relativePath = fileURL.path.replacingOccurrences(of: bundledURL.path, with: "")
            let installedFileURL = installedURL.appendingPathComponent(relativePath)
            if !fileManager.fileExists(atPath: installedFileURL.path) {
                return true
            }
            guard let bundledData = try? Data(contentsOf: fileURL),
                  let installedData = try? Data(contentsOf: installedFileURL) else {
                return true
            }
            if bundledData != installedData {
                return true
            }
        }
        return false
    }

    /// Copies the bundled extension to its stable per-user install location.
    @discardableResult
    static func prepare() throws -> URL {
        guard let bundledDirectoryURL else {
            throw NSError(
                domain: "com.semivpn.app.chrome-extension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The Chrome extension is not included in this SemiVPN build."]
            )
        }

        let fileManager = FileManager.default
        let parentURL = installedDirectoryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let stagingURL = parentURL.appendingPathComponent(
            ".ChromeExtension-\(UUID().uuidString)",
            isDirectory: true
        )
        let backupURL = parentURL.appendingPathComponent(
            ".ChromeExtension-backup-\(UUID().uuidString)",
            isDirectory: true
        )

        defer {
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: backupURL)
        }

        try fileManager.copyItem(at: bundledDirectoryURL, to: stagingURL)

        if fileManager.fileExists(atPath: installedDirectoryURL.path) {
            try fileManager.moveItem(at: installedDirectoryURL, to: backupURL)
            do {
                try fileManager.moveItem(at: stagingURL, to: installedDirectoryURL)
                try fileManager.removeItem(at: backupURL)
            } catch {
                try? fileManager.moveItem(at: backupURL, to: installedDirectoryURL)
                throw error
            }
        } else {
            try fileManager.moveItem(at: stagingURL, to: installedDirectoryURL)
        }

        AppLogger.log("Chrome extension prepared at \(installedDirectoryURL.path)")
        return installedDirectoryURL
    }

    static func revealInstalledDirectory() {
        let directoryURL = isPrepared
            ? installedDirectoryURL
            : installedDirectoryURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    /// Copies the extension folder's path, for the "Load unpacked" dialog
    /// (Command-Shift-G, paste).
    static func copyInstalledDirectoryPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installedDirectoryURL.path, forType: .string)
    }

    /// Opens `browser`'s extensions page. Launch Services can take several
    /// seconds to hand the URL over, so callers should not issue another
    /// request until `completion` runs (on the main queue, with an error
    /// message on failure); each request opens a tab.
    static func openExtensionsPage(in browser: ChromiumBrowser, showingSemiVPN: Bool = false,
                                   completion: @escaping (String?) -> Void = { _ in }) {
        let page = showingSemiVPN ? browser.extensionDetailsPage : browser.extensionsPage
        guard let url = URL(string: page), let applicationURL = browser.applicationURL else {
            AppLogger.log("\(browser.name) is not installed; cannot open its extensions page")
            completion("\(browser.name) is not installed.")
            return
        }

        // Open the URL through the browser directly. Passing chrome:// URLs
        // to NSWorkspace.open(_:) asks Launch Services for a registered
        // handler, which macOS does not provide for internal URL schemes.
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
            if let error {
                AppLogger.log("Could not open the \(browser.name) extensions page: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                completion(error.map { "Could not open \(browser.name): \($0.localizedDescription)" })
            }
        }
    }
}
