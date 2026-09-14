import Foundation

/// App-side debug logger. Disabled by default; enabled from Settings →
/// "Extensive logging". Writes to the app's own Application Support folder.
enum AppLogger {
    static let enabledKey = "extensiveLogging"

    static var enabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: enabledKey) ||
            CommandLine.arguments.contains("--extensive-logging")
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var logURL: URL? {
        SharedConfig.containerURL?.appendingPathComponent("app.log")
    }

    /// Writes a line to the log file; no-op unless extensive logging is on.
    static func log(_ message: String) {
        guard enabled else { return }
        guard let url = logURL else { return }
        let line = "[\(Date())] \(message)\n"
        var text = line
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            text = existing + line
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
