import AppKit
import SwiftUI

/// The public IP addresses this Mac shows the internet, IPv4 and IPv6
/// (only where there is one), without and with the VPN; a click copies
/// one. Opened from the window's toolbar.
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
                section(icon: "lock.shield.fill", tint: .secondary, title: "With VPN", addresses: vpn)
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
        return "Checked at " + checkedAt.formatted(date: .omitted, time: .shortened)
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
                    // No line for a missing IPv6 address.
                    if case .address = addresses.v6 {
                        line("IPv6", addresses.v6)
                    }
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
                CopyableAddress(address: address, font: .system(size: 12.5, weight: .medium).monospacedDigit())
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

/// An IP address that copies itself when clicked, and says so for a
/// moment in its place.
struct CopyableAddress: View {
    let address: String
    let font: Font
    var color: Color = .primary
    /// Shown with "Click to copy" on hover.
    var note: String?
    @State private var copies = 0

    var body: some View {
        Button(action: copy) {
            // The address keeps its width while "Copied" covers it.
            ZStack(alignment: .trailing) {
                Text(address)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(copies > 0 ? 0 : 1)
                if copies > 0 {
                    Label("Copied", systemImage: "checkmark")
                        .font(font)
                        .foregroundStyle(SemiTheme.green)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(LinkPointer())
        .help([note, "Click to copy \(address)"].compactMap { $0 }.joined(separator: " "))
        .accessibilityLabel(address)
        .accessibilityHint("Copies the address")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        copies += 1
        let copy = copies
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            // A later click shows "Copied" for its own 1.2 seconds.
            if copies == copy { copies = 0 }
        }
    }
}

/// The pointing hand over a clickable address (macOS 15 and later).
private struct LinkPointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content
        }
    }
}

/// The addresses in the menu bar panel, checked each time it opens (see
/// MenuBarController): a spinner until they arrive, and IPv6 only where
/// there is one.
struct IPAddressSummary: View {
    @ObservedObject var checker: IPAddressChecker

    var body: some View {
        SectionBox {
            row(icon: "network", tint: .secondary, title: "Without VPN", addresses: checker.regular, first: true)
            row(icon: "lock.shield.fill", tint: .secondary, title: "With VPN", addresses: checker.vpn,
                sameAsRegular: checker.vpn.v4 != .checking && checker.vpn.v4 == checker.regular.v4)
        }
    }

    private func row(icon: String, tint: some ShapeStyle, title: String, addresses: IPAddressView.Addresses,
                     sameAsRegular: Bool = false, first: Bool = false) -> some View {
        SectionRow(first: first) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            switch addresses.v4 {
            case .checking:
                ProgressView().controlSize(.small)
            case .notConnected:
                Text("Not connected")
                    .foregroundStyle(.secondary)
            default:
                VStack(alignment: .trailing, spacing: 1) {
                    if case .address(let address) = addresses.v4 {
                        CopyableAddress(address: address, font: .system(size: 13, weight: .medium).monospacedDigit(),
                                        color: sameAsRegular ? SemiTheme.amber : .primary,
                                        note: sameAsRegular ? "The VPN doesn’t change your address." : nil)
                    } else {
                        Text("Couldn’t check")
                            .foregroundStyle(.secondary)
                    }
                    if case .address(let address) = addresses.v6 {
                        CopyableAddress(address: address, font: .system(size: 10.5).monospacedDigit(), color: .secondary)
                    }
                }
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

#if DEBUG
extension CopyableAddress {
    /// Just clicked, for UISnapshots.
    init(previewCopied address: String, font: Font) {
        self.init(address: address, font: font)
        _copies = State(initialValue: 1)
    }
}

extension IPAddressChecker {
    /// Sample addresses for UISnapshots, which never checks.
    func showPreview(regular: IPAddressView.Addresses, vpn: IPAddressView.Addresses) {
        self.regular = regular
        self.vpn = vpn
        checkedAt = Date()
    }
}
#endif
