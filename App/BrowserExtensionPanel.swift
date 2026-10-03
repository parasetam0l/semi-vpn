import AppKit
import SwiftUI

/// The Browser tab's extension section: which browsers run the extension,
/// whether they are up to date, setup, and the manual-update steps when a
/// browser does not pick a new build up by itself.
struct BrowserExtensionPanel: View {
    @ObservedObject var monitor: ExtensionMonitor
    @State private var setupBrowser: ChromiumBrowser?
    @State private var openingBrowser: ChromiumBrowser?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Browser extension")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                ExtensionStatusPill(monitor: monitor)
            }

            ForEach(monitor.profilesNeedingUpdate) { profile in
                updateBanner(for: profile)
            }

            if monitor.profiles.isEmpty {
                Text(monitor.isPrepared
                     ? "Not detected in a browser yet. Finish the setup, or open the browser if it is closed."
                     : "Routes the domains you list through SemiVPN in Chrome, Edge, Brave and other Chromium browsers. Setup takes about a minute.")
                    .font(.caption)
                    .foregroundStyle(SemiTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.profiles) { profile in
                        ExtensionProfileRow(monitor: monitor, profile: profile) {
                            monitor.forget(profile)
                        }
                        if profile.id != monitor.profiles.last?.id {
                            Rectangle().fill(SemiTheme.line).frame(height: 1)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(SemiTheme.panelRaised.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(SemiTheme.line))
            }

            HStack(spacing: 8) {
                if ChromiumBrowser.installed.isEmpty {
                    Text("No Chromium browser is installed.")
                        .font(.caption)
                        .foregroundStyle(SemiTheme.textMuted)
                } else if ChromiumBrowser.installed.count == 1, let browser = ChromiumBrowser.installed.first {
                    Button(monitor.profiles.isEmpty ? "Set up in \(browser.name)…" : "Set up again…") {
                        setupBrowser = browser
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Menu(monitor.profiles.isEmpty ? "Set up in a browser…" : "Set up in another browser…") {
                        ForEach(ChromiumBrowser.installed) { browser in
                            Button(browser.name) { setupBrowser = browser }
                        }
                    }
                    .fixedSize()
                }
                Button("Show folder") {
                    ChromeExtensionInstaller.revealInstalledDirectory()
                }
                .buttonStyle(.bordered)
                .disabled(!monitor.isPrepared)
                Spacer()
                if let build = monitor.expectedBuild {
                    Text("Extension \(build)")
                        .font(.system(size: 10))
                        .foregroundStyle(SemiTheme.textMuted)
                }
            }
            .controlSize(.small)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $setupBrowser) { browser in
            ExtensionSetupSheet(monitor: monitor, browser: browser) {
                setupBrowser = nil
            }
        }
    }

    // MARK: - Pieces

    private func updateBanner(for profile: ExtensionMonitor.Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Update the extension in \(profile.label)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SemiTheme.amber)
            Text("SemiVPN installed extension \(monitor.expectedBuild.map { BrowserExtension.display($0, comparedTo: profile.report.build) } ?? ""); this browser still runs \(profile.shownBuild(comparedTo: monitor.expectedBuild)). A browser loads a new version of an unpacked extension only when you reload it:")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Open SemiVPN’s entry on the browser’s Extensions page.")
                Text("2. Click the reload button (↻) on “SemiVPN Domain Routing”.")
                Text("Still on the old version after reloading? Remove “SemiVPN Domain Routing” on that page, then add it again with “Set up again…” below. That also fixes a browser that loads the extension from another folder.")
                    .foregroundStyle(SemiTheme.textMuted)
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let browser = profile.browser {
                    Button(openingBrowser == browser ? "Opening \(browser.name)…" : "Open Extensions page") {
                        open(browser)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(openingBrowser != nil)
                }
                Button("Copy folder path") {
                    ChromeExtensionInstaller.copyInstalledDirectoryPath()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(SemiTheme.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(SemiTheme.amber.opacity(0.45)))
    }

    private func open(_ browser: ChromiumBrowser) {
        guard openingBrowser == nil else { return }
        openingBrowser = browser
        ChromeExtensionInstaller.openExtensionsPage(in: browser, showingSemiVPN: true) { error in
            openingBrowser = nil
            message = error
        }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "en_US")   // the app's UI is English
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension ExtensionMonitor {
    enum Summary {
        case updateNeeded, active, browserClosed, notDetected, notSetUp

        var color: Color {
            switch self {
            case .active: return SemiTheme.green
            case .updateNeeded: return SemiTheme.amber
            case .browserClosed, .notDetected, .notSetUp: return SemiTheme.textMuted
            }
        }
    }

    var summary: Summary {
        if !profilesNeedingUpdate.isEmpty { return .updateNeeded }
        if profiles.contains(where: \.isActive) { return .active }
        if !profiles.isEmpty { return .browserClosed }
        return isPrepared ? .notDetected : .notSetUp
    }
}

/// The extension's state in one word: active, update needed, not set up…
struct ExtensionStatusPill: View {
    @ObservedObject var monitor: ExtensionMonitor

    var body: some View {
        let summary = monitor.summary
        let text: String = {
            switch summary {
            case .updateNeeded: return "Update needed"
            case .active: return "Active"
            case .browserClosed: return "Browser closed"
            case .notDetected: return "Not detected"
            case .notSetUp: return "Not set up"
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(summary.color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(summary.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(summary.color.opacity(0.12)))
        .fixedSize()
    }
}

/// The extension's state as a button beside the website search field,
/// where the app list has Add Apps…; it opens Settings → Browser.
struct ExtensionStatusButton: View {
    @ObservedObject var monitor: ExtensionMonitor

    var body: some View {
        let summary = monitor.summary
        Button {
            SettingsWindowController.shared.show(.browser)
        } label: {
            Label {
                Text(title(summary))
            } icon: {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(summary == .notSetUp || summary == .notDetected ? SemiTheme.amber : summary.color)
            }
        }
        .fixedSize()
        .help(help(summary))
    }

    private func title(_ summary: ExtensionMonitor.Summary) -> String {
        switch summary {
        case .updateNeeded: return "Update…"
        case .active: return "Active"
        case .browserClosed: return "Idle"
        case .notDetected, .notSetUp: return "Set Up…"
        }
    }

    private func help(_ summary: ExtensionMonitor.Summary) -> String {
        let browsers = monitor.profiles.filter(\.isActive).map(\.label).joined(separator: ", ")
        switch summary {
        case .active: return "The browser extension is active in \(browsers). Click for its settings."
        case .updateNeeded: return "A browser runs an older version of the extension. Click to see how to update it."
        case .browserClosed: return "The browser extension is set up, but no browser with it is running. Click for its settings."
        case .notDetected, .notSetUp: return "Websites use the VPN only in Chromium browsers with SemiVPN’s extension. Click to set it up."
        }
    }
}

/// A browser profile that runs the extension: its version and when it last
/// checked in.
struct ExtensionProfileRow: View {
    @ObservedObject var monitor: ExtensionMonitor
    let profile: ExtensionMonitor.Profile
    /// Offered on profiles that aren't active; nil: not offered.
    var onForget: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            browserIcon(profile.browser)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.label)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(profile.status == .updateNeeded ? SemiTheme.amber : SemiTheme.textMuted)
            }
            Spacer()
            if !profile.isActive, let onForget {
                Button(action: onForget) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(SemiTheme.textMuted)
                .help("Forget this profile, e.g. after removing the extension from it")
            }
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var detail: String {
        let seen = profile.isActive ? "active now" : "last active " + BrowserExtensionPanel.relative(profile.report.lastSeen)
        let expected = monitor.expectedBuild
        let new = expected.map { BrowserExtension.display($0, comparedTo: profile.report.build) } ?? "the new version"
        switch profile.status {
        case .upToDate:
            return "Up to date · \(profile.version) · \(seen)"
        case .updateNeeded:
            return "Runs \(profile.shownBuild(comparedTo: expected)) · reload it to use \(new)"
        case .outdatedIdle:
            return "Ran \(profile.shownBuild(comparedTo: expected)) · reload it to update when the browser runs · \(seen)"
        }
    }

    private var icon: String {
        switch profile.status {
        case .upToDate: return profile.isActive ? "checkmark.circle.fill" : "moon.zzz"
        case .updateNeeded: return "exclamationmark.triangle.fill"
        case .outdatedIdle: return "clock.arrow.circlepath"
        }
    }

    private var color: Color {
        switch profile.status {
        case .upToDate: return profile.isActive ? SemiTheme.green : SemiTheme.textMuted
        case .updateNeeded: return SemiTheme.amber
        case .outdatedIdle: return SemiTheme.textMuted
        }
    }
}

/// The browser's application icon, or a generic globe.
@ViewBuilder
func browserIcon(_ browser: ChromiumBrowser?) -> some View {
    if let url = browser?.applicationURL {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: 22, height: 22)
    } else {
        Image(systemName: "globe")
            .frame(width: 22, height: 22)
            .foregroundStyle(SemiTheme.textMuted)
    }
}

/// A step-by-step guide for loading the extension into a browser. It
/// completes by itself when the newly loaded extension first checks in.
struct ExtensionSetupSheet: View {
    @ObservedObject var monitor: ExtensionMonitor
    let onClose: () -> Void

    @State private var browser: ChromiumBrowser
    /// Profiles that already ran the extension when the sheet opened.
    @State private var knownProfiles: Set<String>
    @State private var opening = false
    @State private var openedPage = false
    @State private var copied = false
    @State private var error: String?

    init(monitor: ExtensionMonitor, browser: ChromiumBrowser, onClose: @escaping () -> Void) {
        self.monitor = monitor
        self.onClose = onClose
        _browser = State(initialValue: browser)
        _knownProfiles = State(initialValue: Set(monitor.profiles.map(\.id)))
    }

    private var newProfile: ExtensionMonitor.Profile? {
        monitor.profiles.first { !knownProfiles.contains($0.id) }
    }

    private var activeInSelectedBrowser: ExtensionMonitor.Profile? {
        monitor.profiles.first { $0.isActive && $0.report.browser == browser.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                browserIcon(browser)
                    .scaleEffect(1.5)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add SemiVPN to \(browser.name)")
                        .font(.system(size: 17, weight: .bold))
                    Text("A one-time setup per browser profile. After SemiVPN updates, one click on the Extensions page loads the new version.")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                }
                Spacer()
                if ChromiumBrowser.installed.count > 1 {
                    Picker("Browser", selection: $browser) {
                        ForEach(ChromiumBrowser.installed) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if newProfile == nil, let active = activeInSelectedBrowser {
                Label("SemiVPN is already active in \(active.label). Repeat the setup only for another profile.", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(SemiTheme.cyan)
            }

            SetupStep(number: 1, done: openedPage, title: "Open the Extensions page") {
                HStack(spacing: 8) {
                    Button(opening ? "Opening \(browser.name)…" : "Open \(browser.name) Extensions") {
                        openPage()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(opening)
                    Text("or type \(browser.extensionsPage) in the address bar")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SemiTheme.textMuted)
                        .textSelection(.enabled)
                }
            }

            SetupStep(number: 2, done: false, title: "Turn on “Developer mode”") {
                Text("Use the switch in the top-right corner of the Extensions page. It stays on.")
                    .font(.system(size: 11))
                    .foregroundStyle(SemiTheme.textMuted)
            }

            SetupStep(number: 3, done: newProfile != nil, title: "Drag this folder onto the Extensions page") {
                VStack(alignment: .leading, spacing: 8) {
                    folderTile
                    HStack(spacing: 6) {
                        Text("Or click “Load unpacked”, press ⌘⇧G, paste the path and press Return.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(SemiTheme.textMuted)
                        Button(copied ? "Copied" : "Copy path") {
                            ChromeExtensionInstaller.copyInstalledDirectoryPath()
                            copied = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 10) {
                if let profile = newProfile {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(SemiTheme.green)
                    Text("Done. SemiVPN extension \(profile.version) is active in \(profile.label).")
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the extension to check in…")
                        .font(.system(size: 11))
                        .foregroundStyle(SemiTheme.textMuted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(SemiTheme.panelRaised.opacity(0.5)))

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if newProfile != nil {
                    Button("Done", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Close", action: onClose)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear(perform: prepareFolder)
    }

    /// The extension folder, draggable onto the browser's Extensions page.
    private var folderTile: some View {
        let url = ChromeExtensionInstaller.installedDirectoryURL
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("SemiVPN extension folder")
                    .font(.system(size: 12, weight: .semibold))
                Text(url.path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(SemiTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "hand.draw")
                .foregroundStyle(SemiTheme.cyan)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(SemiTheme.panelRaised.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SemiTheme.cyan.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help("Drag onto the Extensions page (with Developer mode on)")
    }

    private func prepareFolder() {
        do {
            if ChromeExtensionInstaller.isPrepared {
                ChromeExtensionInstaller.syncInstalledExtensionIfNeeded()
            } else {
                try ChromeExtensionInstaller.prepare()
            }
            monitor.refresh()
        } catch {
            self.error = "Could not prepare the extension folder: \(error.localizedDescription)"
        }
    }

    private func openPage() {
        guard !opening else { return }
        opening = true
        ChromeExtensionInstaller.openExtensionsPage(in: browser) { message in
            opening = false
            if let message {
                error = message
            } else {
                openedPage = true
            }
        }
    }
}

/// Shown while a browser profile runs an older extension build than the one
/// SemiVPN installed.
struct ExtensionUpdateBanner: View {
    @ObservedObject var monitor: ExtensionMonitor
    let onShowSteps: () -> Void
    @State private var opening = false
    @State private var message: String?

    var body: some View {
        if let profile = monitor.profilesNeedingUpdate.first {
            let count = monitor.profilesNeedingUpdate.count
            let installed = monitor.expectedBuild.map { BrowserExtension.display($0, comparedTo: profile.report.build) } ?? "a new version"
            NoticeCard(
                icon: "arrow.triangle.2.circlepath.circle.fill",
                tint: SemiTheme.amber,
                title: count > 1
                    ? "Update the browser extension in \(count) browser profiles"
                    : "Update the browser extension in \(profile.label)",
                detail: "\(profile.label) runs \(profile.shownBuild(comparedTo: monitor.expectedBuild)); SemiVPN installed \(installed). On the Extensions page, click ↻ on “SemiVPN Domain Routing”.",
                note: message
            ) {
                if let browser = profile.browser {
                    Button(opening ? "Opening…" : "Open Extensions Page") {
                        guard !opening else { return }
                        opening = true
                        ChromeExtensionInstaller.openExtensionsPage(in: browser, showingSemiVPN: true) { error in
                            opening = false
                            message = error
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(opening)
                }
                Button("Show Steps", action: onShowSteps)
            }
        }
    }
}
