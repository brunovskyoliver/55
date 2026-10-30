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
    var cornerRadius: CGFloat = 16
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
    /// Applies the standard agent glass-card effect.
    func agentGlassCard(cornerRadius: CGFloat = 16, tint: Color = .clear) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - Standard spring animation

extension Animation {
    static let agentSpring = Animation.spring(response: 0.32, dampingFraction: 0.72)
}

// MARK: - Glass Section container

/// A titled glass card used as the direct replacement for `Section` outside a `List`.
struct GlassSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentGlassCard()
        }
    }
}

// MARK: - Glass scroll background

/// Dark-glass background for a full-screen scrollable tab.
struct GlassTabBackground: View {
    var body: some View {
        Color.black.opacity(0.85).ignoresSafeArea()
    }
}
