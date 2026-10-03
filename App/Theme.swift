import SwiftUI

/// Colors and button styles shared by the app's windows and sheets.
enum SemiTheme {
    static let canvas = Color(red: 0.025, green: 0.035, blue: 0.095)
    static let sidebar = Color(red: 0.045, green: 0.060, blue: 0.145)
    static let panel = Color(red: 0.065, green: 0.085, blue: 0.19)
    static let panelRaised = Color(red: 0.095, green: 0.125, blue: 0.255)
    static let line = Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.18)
    static let textMuted = Color.white.opacity(0.62)
    static let cyan = Color(red: 0.12, green: 0.82, blue: 1.0)
    static let violet = Color(red: 0.58, green: 0.28, blue: 1.0)
    static let green = Color(red: 0.28, green: 0.88, blue: 0.58)
    static let amber = Color(red: 1.0, green: 0.74, blue: 0.32)
    static let accent = LinearGradient(colors: [cyan, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(SemiTheme.accent)
                    .opacity(configuration.isPressed ? 0.78 : 1.0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct LargeAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.78 : 1.0))
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SemiTheme.accent)
                    .opacity(configuration.isPressed ? 0.78 : 1.0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct LargeDisconnectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.78 : 0.94))
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SemiTheme.panelRaised.opacity(configuration.isPressed ? 0.65 : 0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.red.opacity(0.72), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.5)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.72 : 0.92))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(SemiTheme.panelRaised.opacity(configuration.isPressed ? 0.65 : 0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(SemiTheme.cyan.opacity(0.32), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct DisconnectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.72 : 0.94))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(SemiTheme.panelRaised.opacity(configuration.isPressed ? 0.65 : 0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.red.opacity(0.72), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}
