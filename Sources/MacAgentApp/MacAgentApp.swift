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

        Window("Adapter Debug", id: "adapter-debug") {
            AdapterDebugView(debugState: runtime.adapterDebugState)
                .onDisappear {
                    // Revert to menu-bar-only mode only when no other manageable windows remain.
                    let hasOtherWindows = NSApp.windows.contains {
                        $0.isVisible && $0.canBecomeMain && !$0.title.isEmpty
                    }
                    if !hasOtherWindows { NSApp.setActivationPolicy(.accessory) }
                }
        }
        .defaultSize(width: 900, height: 650)

        Window("Debug / Test", id: "debug-test") {
            DebugTestView(runtime: runtime)
                .onDisappear {
                    let hasOtherWindows = NSApp.windows.contains {
                        $0.isVisible && $0.canBecomeMain && !$0.title.isEmpty
                    }
                    if !hasOtherWindows { NSApp.setActivationPolicy(.accessory) }
                }
        }
        .defaultSize(width: 860, height: 580)
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

    // MARK: - Debug / test panel state
    @Published var discoveredSessions: [DiscoverableSession] = []
    @Published var discoveryStatusText: String?
    @Published var pairingSelfTestRunning = false
    @Published var pairingSelfTestResult: String?

    /// The adapter debug state — bound to the debug window.
    let adapterDebugState: AdapterDebugState

    private let service: DemoControlService
    private let agentEventServer: AgentEventServer
    private let adapter: ClaudeCodeAdapter
    private let secretStore: KeychainPairingSecretStore
    private let pairingService: MacPairingService
    private var server: LocalControlAPIServer?
    private var certFingerprintSHA256: String?
    private var bonjourName: String?
    private var controlBaseURL: URL?

    init() {
        let secretStore = KeychainPairingSecretStore()
        self.secretStore = secretStore
        self.pairingService = MacPairingService(secretStore: secretStore)

        // Set up the adapter event pipeline.
        let agentEventServer = AgentEventServer()
        let debugState = AdapterDebugState()
        let adapter = ClaudeCodeAdapter(debugState: debugState)
        self.agentEventServer = agentEventServer
        self.adapter = adapter
        self.adapterDebugState = debugState

        // Start the loopback event server (non-fatal if it fails).
        var hookServerPort: UInt16 = 0
        do {
            hookServerPort = try agentEventServer.start()
        } catch {
            // Debug state will show disconnected; hooks won't fire but Claude still works.
            debugState.errors.append(.init(message: "AgentEventServer failed to start: \(error)"))
        }

        // Load APNs config if present; push is optional — missing config just disables it.
        let pushSender: APNsPushSender? = {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            let apnsDir = appSupport.appendingPathComponent("AgentSessionControl/apns")
            guard let config = try? APNsConfig.load(from: apnsDir) else { return nil }
            return APNsPushSender(config: config)
        }()

        self.service = DemoControlService(
            sessionStore: SQLiteSessionStore.applicationSupportStore(),
            agentEventServer: hookServerPort > 0 ? agentEventServer : nil,
            adapter: hookServerPort > 0 ? adapter : nil,
            pushSender: pushSender,
            pairingService: pairingService
        )

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
            self.controlBaseURL = result.url
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

    // MARK: - Debug / test panel actions

    func scanSessions() {
        agentLog("[DebugTest] scanning for Claude sessions…", category: .discovery)
        let response = service.listDiscoverableSessions()
        discoveredSessions = response.sessions
        discoveryStatusText = "Found \(response.sessions.count) session(s)."
        agentLog("[DebugTest] scan complete: \(response.sessions.count) session(s)", category: .discovery)
    }

    func focusSession(id: String) {
        agentLog("[DebugTest] attaching/focusing session id=\(id)", category: .focus)
        do {
            _ = try service.attachSession(AttachSessionRequest(sessionID: id))
            agentLog("[DebugTest] attachSession ok", category: .focus)
            ghosttyWarningText = nil
        } catch {
            let msg = "Focus failed: \(error)"
            agentLog("[DebugTest] \(msg)", category: .focus)
            ghosttyWarningText = msg
        }
    }

    func runPairingSelfTest() {
        guard let baseURL = controlBaseURL else {
            pairingSelfTestResult = "✗ Server not started."
            return
        }
        guard let macName = bonjourName, let fingerprint = certFingerprintSHA256 else {
            pairingSelfTestResult = "✗ Server metadata unavailable."
            return
        }
        pairingSelfTestRunning = true
        pairingSelfTestResult = nil
        agentLog("[DebugTest] starting pairing self-test against \(baseURL)", category: .pairing)

        // Run off main thread so UI stays responsive.
        let pairingService = self.pairingService
        Task.detached { [weak self] in
            let result = await performPairingSelfTest(
                pairingService: pairingService,
                baseURL: baseURL,
                macName: macName,
                fingerprint: fingerprint
            )
            await MainActor.run { [weak self] in
                self?.pairingSelfTestRunning = false
                self?.pairingSelfTestResult = result
                agentLog("[DebugTest] pairing self-test result: \(result)", category: .pairing)
            }
        }
    }
}

// MARK: - Pairing self-test implementation

/// Drives a loopback `POST /v1/pairings/complete` against the local HTTPS server.
/// Accepts any server certificate (safe for localhost-only self-test).
private func performPairingSelfTest(
    pairingService: MacPairingService,
    baseURL: URL,
    macName: String,
    fingerprint: String
) async -> String {
    // 1. Generate a fresh invitation.
    let invitation: PairingInvitation
    do {
        invitation = try pairingService.generateInvitation(
            macAgentName: macName,
            controlBaseURL: baseURL,
            timeToLive: 60,
            certFingerprintSHA256: fingerprint
        )
    } catch {
        return "✗ generateInvitation failed: \(error)"
    }

    // 2. Build a fake PairingCompletionRequest (simulates iPhone side).
    let fakePublicKey = Data("fake-public-key-for-self-test".utf8).base64EncodedString()
    let completionRequest = PairingCompletionRequest(
        invitationID: invitation.id,
        invitationSecret: invitation.invitationSecret,
        ownerDeviceName: "Self-Test iPhone",
        ownerDevicePublicKey: fakePublicKey
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let bodyData: Data
    do {
        bodyData = try encoder.encode(completionRequest)
    } catch {
        return "✗ Encoding PairingCompletionRequest failed: \(error)"
    }

    // 3. POST to the local server, accepting self-signed TLS.
    let url = baseURL.appending(path: "v1/pairings/complete")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
    // Short timeout — server is localhost.
    request.timeoutInterval = 10

    let session = URLSession(configuration: .ephemeral, delegate: LoopbackTLSDelegate(), delegateQueue: nil)
    do {
        let (data, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        if httpResponse.statusCode == 200 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode(PairingCompletionResponse.self, from: data)
            return "✓ Pairing self-test passed (HTTP 200, response decoded)."
        } else {
            let body = String(decoding: data, as: UTF8.self)
            return "✗ HTTP \(httpResponse.statusCode): \(body)"
        }
    } catch {
        return "✗ Request failed: \(error)"
    }
}

/// URLSession delegate that accepts any certificate — used only for localhost self-test.
private final class LoopbackTLSDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct MacAgentMenuView: View {
    @ObservedObject var runtime: MacAgentRuntime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.agentGreen)
                    .font(.system(size: 15, weight: .semibold))
                Text("Mac Agent")
                    .font(.headline)
                Spacer()
                if runtime.errorText != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.agentWarning)
                        .font(.caption)
                }
            }

            // QR code (shown while a valid invitation is pending)
            if let payload = runtime.pairingQRPayload {
                MenuCard {
                    VStack(alignment: .center, spacing: 8) {
                        QRCodeView(payload: payload)
                            .frame(width: 160, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Pairing QR Code")
                        Text("Scan with iPhone · Expires \(runtime.pairingExpiresText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(payload, forType: .string)
                        } label: {
                            Label("Copy Pairing Code", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // Status rows
            MenuCard {
                VStack(alignment: .leading, spacing: 6) {
                    StatusRow(title: "Control API", value: runtime.endpointText)
                    Divider()
                    StatusRow(title: "Planning Artifact", value: runtime.activeArtifactTitle)
                    Divider()
                    StatusRow(
                        title: "Agent Session",
                        value: runtime.sessionStateText,
                        accent: runtime.sessionStateText.contains("Running") ? Color.agentGreen : nil
                    )
                    Divider()
                    StatusRow(title: "tmux Attach", value: runtime.tmuxAttachmentText)
                    Divider()
                    StatusRow(
                        title: "Worktree Baseline",
                        value: runtime.baselineText,
                        accent: runtime.baselineText.contains("Dirty") ? Color.agentWarning : nil
                    )
                }
            }

            if let warning = runtime.ghosttyWarningText {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(Color.agentWarning)
            }

            if let errorText = runtime.errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(Color.agentError)
                    .accessibilityLabel("Error: \(errorText)")
            }

            Divider()

            // Action buttons
            VStack(spacing: 4) {
                MenuButton("Refresh", icon: "arrow.clockwise") {
                    runtime.refreshSnapshot()
                }
                MenuButton("Start Session", icon: "play.fill", tint: Color.agentGreen) {
                    runtime.startWrappedSession()
                }
                MenuButton("Open in Ghostty", icon: "terminal") {
                    runtime.openInGhostty()
                }
                MenuButton("Adapter Debug", icon: "rectangle.and.text.magnifyingglass") {
                    openManagedWindow(id: "adapter-debug", title: "Adapter Debug")
                }
                MenuButton("Debug / Test", icon: "stethoscope") {
                    openManagedWindow(id: "debug-test", title: "Debug / Test")
                }
                MenuButton("Quit", icon: "power", tint: Color.agentError) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func openManagedWindow(id: String, title: String) {
        // 1. Switch to regular before creating the window so AeroSpace sees a
        //    regular-policy app from the moment the window appears.
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        // 2. Fire the activation event so AeroSpace re-scans managed windows.
        NSApp.activate(ignoringOtherApps: true)
        // 3. On the next run-loop tick the window exists; ensure it has a
        //    standard style mask so AeroSpace doesn't treat it as a popup
        //    (AXSubrole must be AXStandardWindow, not AXUnknown).
        DispatchQueue.main.async {
            if let win = NSApp.windows.first(where: {
                $0.identifier?.rawValue.contains(id) == true
                    || $0.title == title
            }) {
                win.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
                win.level = .normal
                // .managed tells AeroSpace (and Mission Control) this is a normal
                // tileable document window. Without it, menu-bar app windows default
                // to a transient/non-managed behavior and AeroSpace auto-floats them.
                win.collectionBehavior = [.managed, .participatesInCycle]
                win.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// Rounded material card for grouped content in the menu popover.
private struct MenuCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Full-width labeled button row for the action section.
private struct MenuButton: View {
    let label: String
    let icon: String
    var tint: Color = .primary
    let action: () -> Void

    init(_ label: String, icon: String, tint: Color = .primary, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
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
    var accent: Color? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let accent {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(accent ?? .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Adapter Debug Window

struct AdapterDebugView: View {
    @ObservedObject var debugState: AdapterDebugState

    var body: some View {
        HSplitView {
            // Left column: state + identity
            VStack(alignment: .leading, spacing: 12) {
                Text("Session State")
                    .font(.headline)

                GroupBox("Current State") {
                    VStack(alignment: .leading, spacing: 6) {
                        StateBadge(state: debugState.sessionState)
                        DebugRow(label: "Connection", value: debugState.connectionStatus.displayText)
                        DebugRow(label: "Wrapped Session ID", value: debugState.wrappedSessionID ?? "—")
                        DebugRow(label: "Claude Session ID", value: debugState.claudeSessionID ?? "—")
                        DebugRow(label: "tmux Session", value: debugState.tmuxSessionName ?? "—")
                        DebugRow(label: "tmux Window", value: debugState.tmuxWindowName ?? "—")
                        DebugRow(label: "Hook Server Port", value: debugState.hookServerPort.map { "\($0)" } ?? "—")
                        DebugRow(label: "Transcript Path", value: debugState.transcriptPath ?? "—")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let detail = debugState.pendingInputDetail {
                    GroupBox("Pending Input") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(detail.kind.rawValue).bold()
                                Spacer()
                                Text(detail.confidence.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(detail.confidence == .hookConfirmed ? .green : .orange)
                            }
                            DebugRow(label: "Source", value: detail.source.rawValue)
                            DebugRow(label: "Evidence", value: detail.evidence)
                            if let q = detail.question {
                                DebugRow(label: "Question", value: q)
                            }
                            if !detail.options.isEmpty {
                                DebugRow(label: "Options", value: detail.options.joined(separator: " | "))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !debugState.errors.isEmpty {
                    GroupBox("Errors") {
                        ForEach(debugState.errors) { e in
                            Text("[\(e.occurredAt.formatted(.dateTime.hour().minute().second()))] \(e.message)")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer()
            }
            .padding()
            .frame(minWidth: 280, maxWidth: 320)

            // Right column: logs
            VStack(alignment: .leading, spacing: 8) {
                Text("Adapter Log")
                    .font(.headline)
                    .padding(.horizontal)

                TabView {
                    // State transitions
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(debugState.stateTransitions.reversed()) { t in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("[\(t.timestamp.formatted(.dateTime.hour().minute().second()))] \(t.from.displayName) → \(t.to.displayName)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                    Text(t.evidence)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                        }
                        .padding()
                    }
                    .tabItem { Label("Transitions", systemImage: "arrow.right.arrow.left") }

                    // Hook events
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(debugState.recentHookEvents.reversed()) { e in
                                Text("[\(e.receivedAt.formatted(.dateTime.hour().minute().second()))] \(e.eventName)\(e.toolName.map { " / \($0)" } ?? "")")
                                    .font(.caption.monospaced())
                            }
                        }
                        .padding()
                    }
                    .tabItem { Label("Hook Events", systemImage: "bolt") }

                    // Adapter decisions
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(debugState.adapterDecisions.reversed(), id: \.self) { d in
                                Text(d)
                                    .font(.caption.monospaced())
                            }
                        }
                        .padding()
                    }
                    .tabItem { Label("Decisions", systemImage: "brain") }

                    // Transcript tail
                    ScrollView {
                        Text(debugState.transcriptTail ?? "(no transcript yet)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .tabItem { Label("Transcript Tail", systemImage: "doc.text") }
                }
            }
            .frame(minWidth: 500)
        }
        .frame(minHeight: 500)
    }
}

struct StateBadge: View {
    let state: AdapterSessionState

    var body: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(state.displayName)
                .font(.body.bold())
        }
    }

    private var stateColor: Color {
        switch state {
        case .idle: return .green
        case .working: return .blue
        case .pendingApproval: return .orange
        case .pendingClarification, .pendingUserInput: return .yellow
        case .ended: return .gray
        case .launching, .attaching, .reconnecting: return .purple
        }
    }
}

struct DebugRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

// MARK: - Helpers

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
