#if os(macOS)
import AgentShared
import AppKit
import MacAgentCore
import SwiftUI

@main
struct MacAgentApp: App {
    @StateObject private var runtime = MacAgentRuntime()

    var body: some Scene {
        MenuBarExtra("Mac Agent", systemImage: "bolt.horizontal") {
            MacAgentMenuView(runtime: runtime)
                .frame(width: 320)
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MacAgentRuntime: ObservableObject {
    @Published var endpointText = "Starting..."
    @Published var pairingInvitationText = "Unavailable"
    @Published var pairingExpiresText = "Unavailable"
    @Published var activeArtifactTitle = "No Planning Artifact"
    @Published var sessionStateText = "Unavailable"
    @Published var errorText: String?

    private let service = DemoControlService()
    private let secretStore: KeychainPairingSecretStore
    private let pairingService: MacPairingService
    private var server: LocalControlAPIServer?

    init() {
        let secretStore = KeychainPairingSecretStore()
        self.secretStore = secretStore
        self.pairingService = MacPairingService(secretStore: secretStore)
        start()
        refreshSnapshot()
    }

    func start() {
        do {
            let server = LocalControlAPIServer(
                provider: service,
                pairingService: pairingService,
                securityPolicy: .pairedTLS(PairedControlAPIAuthorizer(secretStore: secretStore)),
                channelSecurity: .pairedTLS
            )
            let baseURL = try server.start()
            self.server = server
            endpointText = baseURL.appending(path: LocalControlAPIServer.foregroundStatePath.trimmingPrefix("/")).absoluteString
            let invitation = try pairingService.generateInvitation(
                macAgentName: Host.current().localizedName ?? "Mac Agent",
                controlBaseURL: baseURL
            )
            pairingInvitationText = try invitation.encodedQRPayload()
            pairingExpiresText = invitation.expiresAt.formatted(date: .omitted, time: .standard)
            errorText = nil
        } catch {
            endpointText = "Unavailable"
            pairingInvitationText = "Unavailable"
            pairingExpiresText = "Unavailable"
            errorText = "Control API failed to start: \(error)"
        }
    }

    func refreshSnapshot() {
        do {
            let response = try service.foregroundState()
            let active = response.planningArtifacts.first { $0.id == response.activePlanningArtifactID }
            activeArtifactTitle = active?.title ?? "No Planning Artifact"
            sessionStateText = response.attachedSessions.first?.session.state.rawValue.capitalized ?? "No Agent Session"
        } catch {
            errorText = "Demo state unavailable: \(error)"
        }
    }
}

struct MacAgentMenuView: View {
    @ObservedObject var runtime: MacAgentRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Mac Agent", systemImage: "bolt.horizontal.fill")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                StatusRow(title: "Control API", value: runtime.endpointText)
                StatusRow(title: "Pairing Invitation", value: runtime.pairingInvitationText)
                StatusRow(title: "Pairing Expires", value: runtime.pairingExpiresText)
                StatusRow(title: "Planning Artifact", value: runtime.activeArtifactTitle)
                StatusRow(title: "Agent Session", value: runtime.sessionStateText)
            }

            if let errorText = runtime.errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(errorText)")
            }

            Divider()

            Button {
                runtime.refreshSnapshot()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
    }
}

struct StatusRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
#else
@main
struct MacAgentApp {
    static func main() {
        print("MacAgentApp is available on macOS.")
    }
}
#endif
