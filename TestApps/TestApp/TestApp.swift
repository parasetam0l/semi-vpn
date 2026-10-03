import SwiftUI

@main
struct SemiTestApp: App {
    var body: some Scene {
        WindowGroup {
            IPView()
                .frame(width: 340, height: 170)
        }
        .windowResizability(.contentSize)
    }
}

struct IPView: View {
    @State private var ip = "checking…"
    @State private var lastUpdate = ""
    @State private var error: String?

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Semi Test")
                .font(.headline)
            Text(ip)
                .font(.system(size: 26, weight: .bold, design: .monospaced))
            Text(lastUpdate)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }

        Button("Refresh") {
            ip = "checking…"
            refresh()
        }
        .buttonStyle(.bordered)
        .disabled(ip == "checking…")
    }

    /// A new connection for every check: a reused one keeps the route it was
    /// opened on, which hides a change in the per-app VPN rules.
    private func refresh() {
        var request = URLRequest(url: URL(string: "https://ifconfig.me/ip")!)
        request.timeoutInterval = 8
        request.setValue("close", forHTTPHeaderField: "Connection")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, _, err in
            session.finishTasksAndInvalidate()
            Self.record(data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "error: \(err?.localizedDescription ?? "no response")")
            DispatchQueue.main.async {
                if let data,
                   let text = String(data: data, encoding: .utf8)?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    ip = text
                    error = nil
                    lastUpdate = "updated \(Self.timeFormatter.string(from: Date()))"
                } else {
                    error = err?.localizedDescription ?? "no response"
                }
            }
        }.resume()
    }

    /// Appends each result to ~/Library/Logs/SemiTest/<bundle id>.log, so a
    /// test can follow it without looking at the window.
    private static func record(_ result: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SemiTest", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent((Bundle.main.bundleIdentifier ?? "semi-test") + ".log")
        let line = "\(timeFormatter.string(from: Date())) \(result)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()
}
