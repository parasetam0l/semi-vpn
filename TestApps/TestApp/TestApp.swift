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

    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

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

    private func refresh() {
        var request = URLRequest(url: URL(string: "https://ifconfig.me/ip")!)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, _, err in
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()
}
