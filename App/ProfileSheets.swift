import AppKit
import OpenVPNCore
import SwiftUI

/// Asks for a profile's username and password and/or key passphrase.
struct CredentialPrompt: View {
    enum Purpose { case connect, save }

    let request: VPNManager.CredentialRequest
    let purpose: Purpose
    let onSubmit: (TunnelSecrets.Credentials, Bool) -> Void
    let onCancel: () -> Void
    var onForget: (() -> Void)? = nil

    @State private var username = ""
    @State private var password = ""
    @State private var passphrase = ""
    @State private var remember = false

    private var canSubmit: Bool {
        (!request.needsUsernamePassword || !username.isEmpty)
            && (!request.needsKeyPassphrase || !passphrase.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(purpose == .connect ? "Sign In to Connect" : "Saved Credentials")
                    .font(.headline)
                Text(request.profileName.replacingOccurrences(of: ".ovpn", with: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Form {
                if request.needsUsernamePassword {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                if request.needsKeyPassphrase {
                    SecureField("Key passphrase", text: $passphrase)
                }
                if purpose == .connect {
                    Toggle("Remember in Keychain", isOn: $remember)
                }
            }
            HStack {
                if let onForget, purpose == .save {
                    Button("Forget", role: .destructive) { onForget() }
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(purpose == .connect ? "Connect" : "Save") {
                    onSubmit(TunnelSecrets.Credentials(
                        username: request.needsUsernamePassword ? username : nil,
                        password: request.needsUsernamePassword ? password : nil,
                        keyPassphrase: request.needsKeyPassphrase ? passphrase : nil
                    ), remember)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            username = request.username ?? ""
        }
    }
}

/// Finds .ovpn files in the folders the user picks and imports the chosen
/// ones.
struct ProfileScanSheet: View {
    let onImport: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Source: CaseIterable {
        case desktop, documents, downloads, openVPN

        var title: String {
            switch self {
            case .desktop: return "Desktop"
            case .documents: return "Documents"
            case .downloads: return "Downloads"
            case .openVPN: return "OpenVPN Connect"
            }
        }

        var directory: String {
            switch self {
            case .desktop: return NSHomeDirectory() + "/Desktop"
            case .documents: return NSHomeDirectory() + "/Documents"
            case .downloads: return NSHomeDirectory() + "/Downloads"
            case .openVPN: return NSHomeDirectory() + "/Library/Application Support/OpenVPN Connect/profiles"
            }
        }
    }

    private struct Found: Identifiable, Hashable {
        let url: URL
        let name: String
        let host: String
        var id: URL { url }
    }

    @State private var sources: Set<Source> = [.desktop, .documents, .downloads]
    @State private var phase: Phase = .choosing
    @State private var found: [Found] = []
    @State private var chosen: Set<URL> = []

    private enum Phase { case choosing, scanning, results }

    /// The OpenVPN Connect folder is offered only when the app is installed.
    private var availableSources: [Source] {
        let openVPNInstalled =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.openvpn.connect.app") != nil
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.openvpn.client.app") != nil
        return Source.allCases.filter { $0 != .openVPN || openVPNInstalled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find Profiles on This Mac")
                .font(.headline)
            switch phase {
            case .choosing:
                Text("Choose where to look for .ovpn files. macOS asks for access to each folder the first time.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(availableSources, id: \.self) { source in
                        Toggle(source.title, isOn: Binding(
                            get: { sources.contains(source) },
                            set: { if $0 { sources.insert(source) } else { sources.remove(source) } }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                buttons(primary: "Find", enabled: !sources.isEmpty, action: scan)
            case .scanning:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Looking for profiles…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
            case .results:
                if found.isEmpty {
                    Text("No .ovpn files in the chosen folders.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                    HStack {
                        Spacer()
                        Button("Close") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(found) { item in
                                Toggle(isOn: Binding(
                                    get: { chosen.contains(item.url) },
                                    set: { if $0 { chosen.insert(item.url) } else { chosen.remove(item.url) } }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name)
                                        Text("\(item.host) · \(item.url.deletingLastPathComponent().lastPathComponent)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    buttons(primary: chosen.count > 1 ? "Import \(chosen.count) Profiles" : "Import",
                            enabled: !chosen.isEmpty) {
                        onImport(found.map(\.url).filter { chosen.contains($0) })
                        dismiss()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func buttons(primary: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(primary, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled)
        }
    }

    private func scan() {
        phase = .scanning
        let directories = availableSources.filter { sources.contains($0) }.map(\.directory)
        // Listing and parsing happen off the main thread. A folder is read
        // only after the user chose it, so macOS asks for access then.
        Task.detached(priority: .userInitiated) {
            var results: [Found] = []
            for directory in directories {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                for file in files.sorted() where file.hasSuffix(".ovpn") {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent(file)
                    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let name = AppModel.certificateCommonName(in: text) ?? url.deletingPathExtension().lastPathComponent
                    let host = (try? OVPNParser().parse(text))?.remotes.first?.host ?? "unknown"
                    results.append(Found(url: url, name: name, host: host))
                }
            }
            await MainActor.run {
                found = results
                chosen = Set(results.map(\.url))
                phase = .results
            }
        }
    }
}
