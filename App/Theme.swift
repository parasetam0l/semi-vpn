import AppKit
import SwiftUI

/// SemiVPN's colors and shared building blocks. Surfaces and text use the
/// system's adaptive colors, so the app follows light and dark mode; the
/// cyan and violet come from the app icon.
enum SemiTheme {
    static let cyan = Color(red: 0.10, green: 0.68, blue: 0.96)
    static let violet = Color(red: 0.52, green: 0.30, blue: 0.98)
    /// The tint of buttons, switches and selections.
    static let brand = Color(red: 0.33, green: 0.42, blue: 0.98)
    static let gradient = LinearGradient(colors: [cyan, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let green = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemOrange)

    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Grouped sections and rows.
    static let panel = Color.primary.opacity(0.045)
    static let panelRaised = Color.primary.opacity(0.08)
    static let line = Color.primary.opacity(0.10)
    static let textMuted = Color.secondary
}

/// A rounded group of rows, like a section in System Settings.
struct SectionBox<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                content
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SemiTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SemiTheme.line, lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One row of a `SectionBox`, with a divider above all but the first.
struct SectionRow<Content: View>: View {
    var first = false
    var verticalPadding: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !first {
                Rectangle().fill(SemiTheme.line).frame(height: 0.5).padding(.leading, 12)
            }
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Something that needs the user's attention, above the main content.
struct NoticeCard<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var detail: String?
    var note: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                actions
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.11)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
    }
}

/// The connection state as a shield in a circle: the icon's colors when
/// connected, orange while changing, grey when off.
struct StatusOrb: View {
    let state: OrbState
    var size: CGFloat = 76

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
            if state == .connected {
                Circle()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
        }
        .frame(width: size, height: size)
        .shadow(color: state == .connected ? SemiTheme.violet.opacity(0.35) : .clear, radius: size * 0.18, y: size * 0.06)
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .connected: return AnyShapeStyle(SemiTheme.gradient)
        case .changing: return AnyShapeStyle(SemiTheme.amber.gradient)
        case .off: return AnyShapeStyle(SemiTheme.panelRaised)
        }
    }

    private var symbol: String {
        switch state {
        case .connected: return "checkmark.shield.fill"
        case .changing: return "shield.lefthalf.filled"
        case .off: return "shield"
        }
    }
}

/// The three looks of the status orb.
enum OrbState {
    case connected, changing, off
}

/// A numbered step of a setup sheet; the number turns into a check mark
/// when the step is done.
struct SetupStep<Content: View>: View {
    let number: Int
    let done: Bool
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? SemiTheme.green.opacity(0.18) : SemiTheme.panelRaised)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(SemiTheme.green)
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .bold))
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
