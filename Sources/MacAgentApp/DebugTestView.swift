#if os(macOS)
import AgentShared
import AppKit
import MacAgentCore
import SwiftUI

// MARK: - Debug / Test window

/// One-stop panel for triggering and observing all the subsystems the Mac Agent controls:
///  • Session discovery  (scan for running Claude sessions)
///  • Focus / attach     (trigger tmux focus + Ghostty raise for a specific session)
///  • Pairing self-test  (loopback HTTP POST /v1/pairings/complete without the phone)
///  • Live log           (ring buffer fed by AgentLog throughout the whole app)
struct DebugTestView: View {
    @ObservedObject var runtime: MacAgentRuntime
    @ObservedObject private var logStore = AgentLogStore.shared

    var body: some View {
        HSplitView {
            // Left: actions + session list
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    discoverySection
                    pairingSection
                }
                .padding()
            }
            .frame(minWidth: 340, idealWidth: 380)

            // Right: live log
            logSection
                .frame(minWidth: 380, idealWidth: 500)
        }
        .frame(minHeight: 500)
    }

    // MARK: - Discovery section

    private var discoverySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Session Discovery")
                        .font(.headline)
                    Spacer()
                    Button("Scan") {
                        runtime.scanSessions()
                    }
                    .controlSize(.small)
                }

                if runtime.discoveredSessions.isEmpty {
                    Text("No sessions found — tap Scan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(runtime.discoveredSessions) { session in
                        SessionRowView(session: session) {
                            runtime.focusSession(id: session.id)
                        }
                        Divider()
                    }
                }

                if let msg = runtime.discoveryStatusText {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Pairing self-test section

    private var pairingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Pairing Self-Test")
                        .font(.headline)
                    Spacer()
                    Button("Run") {
                        runtime.runPairingSelfTest()
                    }
                    .controlSize(.small)
                    .disabled(runtime.pairingSelfTestRunning)
                }

                Text("Generates an invitation and posts a loopback PairingCompletionRequest to the local HTTPS server — end-to-end without the iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let result = runtime.pairingSelfTestResult {
                    Text(result)
                        .font(.caption.monospaced())
                        .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.agentError)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Log section

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live Log")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                Spacer()
                Button("Clear") {
                    AgentLogStore.shared.clear()
                }
                .controlSize(.small)
                .padding(.trailing, 12)
                .padding(.top, 12)
            }

            Divider()
                .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logStore.entries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: logStore.entries.count) { _, _ in
                    if let last = logStore.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(.background)
    }
}

// MARK: - Session row

private struct SessionRowView: View {
    let session: DiscoverableSession
    let onFocus: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    kindBadge
                    Text(session.tmuxSessionName ?? session.id)
                        .font(.callout.bold())
                        .textSelection(.enabled)
                    if session.hookWired {
                        Image(systemName: "link.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                if let window = session.tmuxWindowName {
                    Text("window: \(window)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !session.repoPath.isEmpty {
                    Text(session.repoPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                Text(session.lastActivity, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Focus") { onFocus() }
                .controlSize(.mini)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    private var kindBadge: some View {
        Text(session.kind.badgeLabel)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(session.kind.badgeColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(session.kind.badgeColor)
    }
}

private extension DiscoverableSession.Kind {
    var badgeLabel: String {
        switch self {
        case .agentLaunched: return "Agent"
        case .externalTmux:  return "tmux"
        case .bareGhostty:   return "Ghostty"
        }
    }

    var badgeColor: Color {
        switch self {
        case .agentLaunched: return .green
        case .externalTmux:  return .blue
        case .bareGhostty:   return .orange
        }
    }
}

// MARK: - Log entry row

private struct LogEntryRow: View {
    let entry: AgentLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp, style: .time)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .fixedSize()

            Text(entry.category.rawValue.uppercased())
                .font(.caption2.bold())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(categoryColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(categoryColor)
                .fixedSize()

            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var categoryColor: Color {
        switch entry.category {
        case .pairing:   return .purple
        case .discovery: return .blue
        case .focus:     return .orange
        case .http:      return .teal
        case .general:   return .primary
        }
    }
}
#endif
