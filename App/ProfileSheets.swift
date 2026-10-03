import AppKit
import OpenVPNCore
import SwiftUI
import UniformTypeIdentifiers

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
/// ones. Laid out like the browser extension's setup sheet.
struct ProfileScanSheet: View {
    let onImport: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Source: CaseIterable, Identifiable {
        case desktop, documents, downloads, openVPN

        var id: Self { self }

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

    fileprivate struct Found: Identifiable, Hashable {
        let url: URL
        let name: String
        let host: String
        /// The folder it was found in, as the user chose it.
        let folder: String
        var id: URL { url }
    }

    @State private var sources: Set<Source> = [.desktop, .documents, .downloads]
    @State private var phase: Phase = .choosing
    @State private var found: [Found] = []
    @State private var chosen: Set<URL> = []

    fileprivate enum Phase { case choosing, scanning, results }

    /// The list shows this many profiles before it scrolls.
    private static let visibleRows = 6
    private static let rowHeight: CGFloat = 42

    /// The OpenVPN Connect folder is offered only when the app is installed.
    private var availableSources: [Source] {
        let openVPNInstalled =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.openvpn.connect.app") != nil
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.openvpn.client.app") != nil
        return Source.allCases.filter { $0 != .openVPN || openVPNInstalled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find Profiles on This Mac")
                        .font(.system(size: 17, weight: .bold))
                    Text("SemiVPN looks for OpenVPN profiles (.ovpn files) and imports the ones you choose. It keeps its own copy of each.")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SetupStep(number: 1, done: phase == .results, title: "Choose where to look") {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(availableSources) { source in
                            Toggle(source.title, isOn: Binding(
                                get: { sources.contains(source) },
                                set: { if $0 { sources.insert(source) } else { sources.remove(source) } }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    HStack(spacing: 8) {
                        if phase == .results {
                            Button("Search Again", action: scan)
                                .buttonStyle(.bordered)
                                .disabled(sources.isEmpty)
                        } else {
                            Button("Find Profiles", action: scan)
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                                .disabled(sources.isEmpty || phase == .scanning)
                        }
                        if phase == .scanning {
                            ProgressView().controlSize(.small)
                            Text("Looking for profiles…")
                                .font(.system(size: 11))
                                .foregroundStyle(SemiTheme.textMuted)
                        } else {
                            Text("macOS asks for access to each folder the first time.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(SemiTheme.textMuted)
                        }
                    }
                }
            }

            SetupStep(number: 2, done: false, title: "Choose the profiles to import") {
                switch phase {
                case .choosing, .scanning:
                    Text("The profiles SemiVPN finds appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                case .results:
                    if found.isEmpty {
                        Text("No .ovpn files in the chosen folders. Choose other folders, or use Import Profile… to pick a file.")
                            .font(.system(size: 11))
                            .foregroundStyle(SemiTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        resultList
                    }
                }
            }

            HStack(spacing: 8) {
                if phase == .results, found.count > 1 {
                    Button(chosen.count == found.count ? "Deselect All" : "Select All") {
                        chosen = chosen.count == found.count ? [] : Set(found.map(\.url))
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Import \(chosen.count) Profiles" : "Import") {
                    onImport(found.map(\.url).filter { chosen.contains($0) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(phase == .results ? .defaultAction : nil)
                .disabled(phase != .results || chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private var resultList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(found) { item in
                    resultRow(item)
                        .overlay(alignment: .top) {
                            if item.id != found.first?.id {
                                Rectangle().fill(SemiTheme.line).frame(height: 1)
                            }
                        }
                }
            }
        }
        .frame(height: CGFloat(min(found.count, Self.visibleRows)) * Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(SemiTheme.panelRaised.opacity(0.45)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(SemiTheme.line))
    }

    private func resultRow(_ item: Found) -> some View {
        let isChosen = Binding(
            get: { chosen.contains(item.url) },
            set: { if $0 { chosen.insert(item.url) } else { chosen.remove(item.url) } }
        )
        return HStack(spacing: 10) {
            Toggle(item.name, isOn: isChosen)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(nsImage: Self.profileIcon)
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(item.host) · \(item.folder)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SemiTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { isChosen.wrappedValue.toggle() }
        .help(item.url.path)
    }

    private static let profileIcon = NSWorkspace.shared.icon(for: UTType(filenameExtension: "ovpn") ?? .data)

    private func scan() {
        phase = .scanning
        let folders = availableSources.filter { sources.contains($0) }.map { ($0.directory, $0.title) }
        // Listing and parsing happen off the main thread. A folder is read
        // only after the user chose it, so macOS asks for access then.
        Task.detached(priority: .userInitiated) {
            var results: [Found] = []
            for (directory, title) in folders {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                for file in files.sorted() where file.hasSuffix(".ovpn") {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent(file)
                    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let name = AppModel.certificateCommonName(in: text) ?? url.deletingPathExtension().lastPathComponent
                    let host = (try? OVPNParser().parse(text))?.remotes.first?.host ?? "unknown"
                    results.append(Found(url: url, name: name, host: host, folder: title))
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

#if DEBUG
extension ProfileScanSheet {
    /// Sample results for UISnapshots: name, host and folder of each.
    init(previewResults: [(name: String, host: String, folder: String)]) {
        let found = previewResults.map {
            Found(url: URL(fileURLWithPath: "/tmp/\($0.name).ovpn"), name: $0.name, host: $0.host, folder: $0.folder)
        }
        self.init(onImport: { _ in })
        _found = State(initialValue: found)
        _chosen = State(initialValue: Set(found.map(\.url)))
        _phase = State(initialValue: .results)
    }
}
#endif
