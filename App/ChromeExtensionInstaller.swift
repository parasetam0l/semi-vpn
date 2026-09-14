import AppKit
import Foundation

/// Prepares the bundled Chrome extension for Chrome's one-time "Load
/// unpacked" flow. Chrome on macOS does not allow a regular app to silently
/// install a local CRX, so the extension is copied to a stable user directory
/// that survives SemiVPN app updates.
enum ChromeExtensionInstaller {
    private static let applicationSupportDirectoryName = "SemiVPN"
    static let extensionDirectoryName = "ChromeExtension"

    static var installedDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(extensionDirectoryName, isDirectory: true)
    }

    static var isPrepared: Bool {
        FileManager.default.fileExists(
            atPath: installedDirectoryURL.appendingPathComponent("manifest.json").path
        )
    }

    /// Checks whether the installed extension differs from the bundled extension and updates it automatically.
    @discardableResult
    static func syncInstalledExtensionIfNeeded() -> Bool {
        guard isPrepared,
              let bundledDirectoryURL = Bundle.main.url(forResource: extensionDirectoryName, withExtension: nil) else {
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
        guard let bundledDirectoryURL = Bundle.main.url(
            forResource: extensionDirectoryName,
            withExtension: nil
        ) else {
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

    static func openChromeExtensionSettings() {
        guard let url = URL(string: "chrome://extensions") else { return }
        guard let chromeURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.Chrome"
        ) else {
            AppLogger.log("Google Chrome is not installed; cannot open extension settings")
            return
        }

        // Open the URL through Chrome directly. Passing chrome://extensions to
        // NSWorkspace.open(_:) asks Launch Services for a registered handler,
        // which macOS does not provide for Chrome's internal URL scheme.
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: chromeURL,
            configuration: configuration
        ) { _, error in
            if let error {
                AppLogger.log("Could not open Chrome extension settings: \(error.localizedDescription)")
            }
        }
    }
}
