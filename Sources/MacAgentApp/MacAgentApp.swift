#if os(macOS)
import AgentShared
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MacAgentCore
import SwiftUI

@main
struct MacAgentApp: App {
    @StateObject private var runtime = MacAgentRuntime()

    var body: some Scene {
        MenuBarExtra("Mac Agent", systemImage: "bolt.horizontal") {
            MacAgentMenuView(runtime: runtime)
                .frame(minWidth: 280, maxWidth: 420)
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MacAgentRuntime: ObservableObject {
    @Published var endpointText = "Starting..."
    @Published var pairingExpiresText = "Unavailable"
    @Published var pairingQRPayload: String?   // nil → no QR yet
    @Published var activeArtifactTitle = "No Planning Artifact"
    @Published var sessionStateText = "Unavailable"
    @Published var tmuxAttachmentText = "Unavailable"
    @Published var baselineText = "Unavailable"
    @Published var errorText: String?
    @Published var ghosttyWarningText: String?

    private let service = DemoControlService(sessionStore: SQLiteSessionStore.applicationSupportStore())
    private let secretStore: KeychainPairingSecretStore
    private let pairingService: MacPairingService
    private var server: LocalControlAPIServer?
    private var certFingerprintSHA256: String?
    private var bonjourName: String?

    init() {
        let secretStore = KeychainPairingSecretStore()
        self.secretStore = secretStore
        self.pairingService = MacPairingService(secretStore: secretStore)
        start()
        refreshSnapshot()
    }

    func start() {
        do {
            let macName = Host.current().localizedName ?? "Mac Agent"
            let server = LocalControlAPIServer(
                provider: service,
                pairingService: pairingService,
                securityPolicy: .pairedTLS(PairedControlAPIAuthorizer(secretStore: secretStore)),
                channelSecurity: .pairedTLS,
                bonjourServiceName: macName
            )
            let result = try server.start()
            self.server = server
            self.certFingerprintSHA256 = result.certFingerprintSHA256
            self.bonjourName = macName
            endpointText = result.url.appending(path: LocalControlAPIServer.foregroundStatePath.trimmingPrefix("/")).absoluteString

            let invitation = try pairingService.generateInvitation(
                macAgentName: macName,
                controlBaseURL: result.url,
                certFingerprintSHA256: result.certFingerprintSHA256,
                bonjourServiceName: macName
            )
            pairingQRPayload = try invitation.encodedQRPayload()
            pairingExpiresText = invitation.expiresAt.formatted(date: .omitted, time: .standard)
            errorText = nil
        } catch {
            endpointText = "Unavailable"
            pairingQRPayload = nil
            pairingExpiresText = "Unavailable"
            errorText = "Control API failed to start: \(error)"
        }
    }

    func refreshSnapshot() {
        do {
            let response = try service.foregroundState()
            let active = response.planningArtifacts.first { $0.id == response.activePlanningArtifactID }
            let session = response.attachedSessions.first?.session
            activeArtifactTitle = active?.title ?? "No Planning Artifact"
            sessionStateText = session?.state.rawValue.capitalized ?? "No Agent Session"
            tmuxAttachmentText = session?.tmuxAttachment?.attachCommand ?? "No tmux session"
            baselineText = session?.worktreeBaseline?.summary ?? "No Worktree Baseline"
        } catch {
            errorText = "Demo state unavailable: \(error)"
        }
    }

    func startWrappedSession() {
        do {
            _ = try service.startWrappedSession()
            refreshSnapshot()
            errorText = nil
            openInGhostty()
        } catch {
            errorText = "Wrapped Session failed to start: \(error)"
            refreshSnapshot()
        }
    }

    func openInGhostty() {
        guard tmuxAttachmentText != "No tmux session", !tmuxAttachmentText.isEmpty else {
            ghosttyWarningText = "No active tmux session to open."
            return
        }
        // Session name is last token of "tmux attach-session -t <name>"
        let sessionName = tmuxAttachmentText.split(separator: " ").last.map(String.init) ?? ""
        let launcher = GhosttyLauncher()
        if let warning = launcher.openOrFocus(attachCommand: tmuxAttachmentText, sessionName: sessionName) {
            ghosttyWarningText = warning
        } else {
            ghosttyWarningText = nil
        }
    }
}

struct MacAgentMenuView: View {
    @ObservedObject var runtime: MacAgentRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Mac Agent", systemImage: "bolt.horizontal.fill")
                .font(.headline)

            // QR code (shown while a valid invitation is pending)
            if let payload = runtime.pairingQRPayload {
                VStack(alignment: .center, spacing: 6) {
                    QRCodeView(payload: payload)
                        .frame(width: 180, height: 180)
                        .accessibilityLabel("Pairing QR Code")
                    Text("Scan with iPhone to pair · Expires \(runtime.pairingExpiresText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 8) {
                StatusRow(title: "Control API", value: runtime.endpointText)
                StatusRow(title: "Planning Artifact", value: runtime.activeArtifactTitle)
                StatusRow(title: "Agent Session", value: runtime.sessionStateText)
                StatusRow(title: "tmux Attach", value: runtime.tmuxAttachmentText)
                StatusRow(title: "Worktree Baseline", value: runtime.baselineText)
            }

            if let warning = runtime.ghosttyWarningText {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
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

            Button {
                runtime.startWrappedSession()
            } label: {
                Label("Start Wrapped Session", systemImage: "play.fill")
            }

            Button {
                runtime.openInGhostty()
            } label: {
                Label("Open in Ghostty", systemImage: "terminal")
            }

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
    }
}

/// Renders a string as a QR code image using CoreImage.
struct QRCodeView: View {
    let payload: String

    var body: some View {
        if let image = generateQRCode(from: payload) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            // Fallback: selectable text if CoreImage QR generation fails.
            Text(payload)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up from the native ~33×33 pixel output to something legible.
        let scale = 6.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaled = output.transformed(by: transform)
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
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
                .fixedSize(horizontal: false, vertical: true)
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
