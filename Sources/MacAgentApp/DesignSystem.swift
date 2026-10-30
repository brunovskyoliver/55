import SwiftUI

// MARK: - Palette (bagent-inspired: dark glass + green accent)

extension Color {
    /// Primary action / status-running green (#30d158).
    static let agentGreen = Color(red: 0.18, green: 0.80, blue: 0.44)
    /// Warning / dirty-worktree amber.
    static let agentWarning = Color(red: 1.00, green: 0.78, blue: 0.15)
    /// Error / stop red.
    static let agentError = Color(red: 0.95, green: 0.27, blue: 0.27)
    /// Link / info blue.
    static let agentBlue = Color(red: 0.20, green: 0.60, blue: 1.00)
}

// MARK: - Glass card modifier

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var tint: Color = .clear

    func body(content: Content) -> some View {
        content
            .glassEffect(
                tint == .clear
                    ? .regular
                    : .regular.tint(tint),
                in: .rect(cornerRadius: cornerRadius)
            )
    }
}

extension View {
    func agentGlassCard(cornerRadius: CGFloat = 14, tint: Color = .clear) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - Standard spring animation

extension Animation {
    static let agentSpring = Animation.spring(response: 0.32, dampingFraction: 0.72)
}
