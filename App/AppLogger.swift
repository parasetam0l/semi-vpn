import Foundation

/// App-side debug logger. Disabled by default; enabled from Settings →
/// "Extensive logging". Writes to the app's own Application Support folder.
///
/// The app and SemiProxy log to the same file: each line is one
/// `O_APPEND` write, which the kernel keeps atomic across processes, and the
/// file is rotated to `app.log.1` when it grows past 5 MB.
enum AppLogger {
    static let enabledKey = "extensiveLogging"
    static let maxSize: off_t = 5 * 1024 * 1024
    private static let queue = DispatchQueue(label: "com.semivpn.app-logger")

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

    /// Appends a line to the log file; no-op unless extensive logging is on.
    static func log(_ message: String) {
        guard enabled, let url = logURL else { return }
        let line = "[\(Date())] [\(ProcessInfo.processInfo.processName)] \(message)\n"
        queue.async {
            SharedConfig.ensureDirectories()
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var info = stat()
            if fstat(fd, &info) == 0, info.st_size > maxSize {
                let rotated = url.path + ".1"
                unlink(rotated)
                rename(url.path, rotated)
            }
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        }
    }
}
