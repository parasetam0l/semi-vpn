import AppKit
import SwiftUI

/// The public IP addresses this Mac shows the internet, IPv4 and IPv6,
/// without and with the VPN. Opened from the window's toolbar.
struct IPAddressView: View {
    enum Value: Equatable {
        case checking
        case address(String)
        /// No address of this family (e.g. no IPv6 on the network).
        case none
        case notConnected
        case failed(String)
    }

    struct Addresses: Equatable {
        var v4: Value
        var v6: Value
    }

    var regular: Addresses
    var vpn: Addresses
    var checkedAt: Date?
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("IP Addresses")
                .font(.system(size: 13, weight: .semibold))
            SectionBox {
                section(icon: "network", tint: .secondary, title: "Without VPN", addresses: regular, first: true)
                section(icon: "lock.shield.fill", tint: SemiTheme.brand, title: "With VPN", addresses: vpn)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(SemiTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled([regular.v4, regular.v6, vpn.v4, vpn.v6].contains(.checking))
                Spacer()
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    /// The VPN doesn't change an address it should.
    private var warning: String? {
        if case .address(let address) = vpn.v4, regular.v4 == .address(address) {
            return "Both IPv4 addresses are the same: the VPN doesn’t change your address."
        }
        if case .address(let address) = vpn.v6, regular.v6 == .address(address) {
            return "Both IPv6 addresses are the same: IPv6 bypasses the VPN."
        }
        return nil
    }

    private var footer: String {
        guard let checkedAt else { return "From icanhazip.com" }
        return "Checked " + BrowserExtensionPanel.relative(checkedAt)
    }

    private func section(icon: String, tint: some ShapeStyle, title: String,
                         addresses: Addresses, first: Bool = false) -> some View {
        SectionRow(first: first, verticalPadding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if addresses.v4 == .notConnected {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                    }
                }
                if addresses.v4 != .notConnected {
                    line("IPv4", addresses.v4)
                    line("IPv6", addresses.v6)
                }
            }
        }
    }

    private func line(_ family: String, _ value: Value) -> some View {
        HStack(spacing: 8) {
            Text(family)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
                .padding(.leading, 26)
            Spacer(minLength: 8)
            switch value {
            case .checking:
                ProgressView().controlSize(.mini)
            case .address(let address):
                Text(address)
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            case .none:
                Text("None")
                    .foregroundStyle(.secondary)
            case .notConnected:
                Text("Not connected")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("Couldn’t check")
                    .foregroundStyle(.secondary)
                    .help(message)
            }
        }
    }
}

/// The window toolbar's globe button and its IP popover.
struct IPAddressButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var checker = IPAddressChecker.shared
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label("IP Addresses", systemImage: "globe")
        }
        .help("IP addresses without and with the VPN")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            IPAddressView(regular: checker.regular, vpn: checker.vpn, checkedAt: checker.checkedAt,
                          onRefresh: refresh)
                .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        checker.refresh(vpnConnected: model.vpn.status == .connected)
    }
}

/// Looks up the addresses for the IP popover: SemiVPN's own without the
/// VPN, and SemiProxy's, which macOS routes through the VPN, with it.
@MainActor
final class IPAddressChecker: ObservableObject {
    static let shared = IPAddressChecker()

    @Published private(set) var regular = IPAddressView.Addresses(v4: .checking, v6: .checking)
    @Published private(set) var vpn = IPAddressView.Addresses(v4: .checking, v6: .checking)
    @Published private(set) var checkedAt: Date?
    /// Only the latest refresh shows its results.
    private var generation = 0

    func refresh(vpnConnected: Bool) {
        generation += 1
        let current = generation
        regular = .init(v4: .checking, v6: .checking)
        vpn = vpnConnected ? .init(v4: .checking, v6: .checking) : .init(v4: .notConnected, v6: .notConnected)
        Task {
            async let direct = PublicIPLookup.lookUp(avoidingTunnels: true)
            async let tunneled = vpnConnected ? Self.lookUpThroughHelper() : nil
            let (withoutVPN, withVPN) = await (direct, tunneled)
            guard current == generation else { return }
            regular = Self.addresses(withoutVPN)
            if vpnConnected {
                vpn = withVPN.map(Self.addresses)
                    ?? .init(v4: .failed("SemiVPN’s helper didn’t answer."), v6: .failed("SemiVPN’s helper didn’t answer."))
            }
            checkedAt = Date()
            AppLogger.log("ip check: without VPN \(withoutVPN), with VPN \(withVPN.map { "\($0)" } ?? "-")")
        }
    }

    private static func addresses(_ result: PublicIPLookup.Result) -> IPAddressView.Addresses {
        func value(_ outcome: PublicIPLookup.Outcome, ipv6: Bool) -> IPAddressView.Value {
            switch outcome {
            case .address(let address): return .address(address)
            // Most networks without IPv6 just fail to connect.
            case .unavailable(let reason): return ipv6 ? .none : .failed(reason)
            }
        }
        return .init(v4: value(result.v4, ipv6: false), v6: value(result.v6, ipv6: true))
    }

    /// Launches a copy of SemiProxy with `--public-ip`, which writes the
    /// addresses its traffic shows to a file. It must be launched through
    /// LaunchServices, like the running helper: macOS attributes a process
    /// SemiVPN spawns itself to SemiVPN, which the per-app rules don't
    /// route (tested: such a copy showed the address without the VPN).
    nonisolated private static func lookUpThroughHelper() async -> PublicIPLookup.Result? {
        guard let helperURL = VPNManager.proxyHelperAppURL else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("semivpn-public-ip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--public-ip", "--output", output.path]
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        let helper: NSRunningApplication
        do {
            helper = try await NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration)
        } catch {
            AppLogger.log("ip check: couldn’t launch SemiProxy: \(error)")
            return nil
        }
        // Its lookups give up after 8 seconds.
        let deadline = Date().addingTimeInterval(20)
        while !helper.isTerminated, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !helper.isTerminated {
            helper.forceTerminate()
            return nil
        }
        guard let data = try? Data(contentsOf: output) else { return nil }
        return try? JSONDecoder().decode(PublicIPLookup.Result.self, from: data)
    }
}
