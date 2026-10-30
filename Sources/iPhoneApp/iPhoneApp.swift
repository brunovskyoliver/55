import AgentShared
import Foundation
import iPhoneCore
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
import VisionKit
#endif

#if os(iOS)

// MARK: - AppDelegate

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: "AgentSessionControl.pushTokenHex")
        NotificationCenter.default.post(name: .pushTokenDidUpdate, object: hex)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}

extension Notification.Name {
    static let pushTokenDidUpdate = Notification.Name("AgentSessionControl.pushTokenDidUpdate")
}

public struct iPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    public init() {}
    public var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// Top-level view that switches between the pairing screen and the main planning UI.
public struct AppRootView: View {
    public init() {}
    @State private var credentials: PairedControlCredentials? = loadStoredCredentials()
    @State private var localDisconnectWarning: String?

    public var body: some View {
        Group {
            if let creds = credentials {
                PlanningCenteredRootView(
                    loader: .pairedAPI(credentials: creds),
                    credentials: creds,
                    onDisconnected: {
                        localDisconnectWarning = nil
                        credentials = nil
                    },
                    onLocalDisconnect: { warning in
                        clearStoredCredentials()
                        localDisconnectWarning = warning
                        credentials = nil
                    }
                )
            } else {
                PairingView(localDisconnectWarning: localDisconnectWarning) { paired in
                    localDisconnectWarning = nil
                    storeCredentials(paired)
                    credentials = paired
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: credentials?.deviceID) {
            guard let creds = credentials else { return }
            await registerStoredPushTokenIfAvailable(credentials: creds)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushTokenDidUpdate)) { _ in
            guard let creds = credentials else { return }
            Task { await registerStoredPushTokenIfAvailable(credentials: creds) }
        }
    }
}

private func registerStoredPushTokenIfAvailable(credentials: PairedControlCredentials) async {
    guard let hex = UserDefaults.standard.string(forKey: "AgentSessionControl.pushTokenHex"),
          !hex.isEmpty else { return }
    #if DEBUG
    let environment = "development"
    #else
    let environment = "production"
    #endif
    let client = HTTPForegroundStateClient(baseURL: credentials.controlBaseURL, credentials: credentials)
    try? await client.registerPushToken(RegisterPushTokenRequest(token: hex, environment: environment))
}

// MARK: - Credential persistence (UserDefaults + Keychain)

private func loadStoredCredentials() -> PairedControlCredentials? {
    guard let deviceID = UserDefaults.standard.string(forKey: "AgentSessionControl.pairedDeviceID") else {
        return nil
    }
    let store = KeychainPairedControlCredentialStore()
    return try? store.credentials(forDeviceID: deviceID)
}

private func storeCredentials(_ credentials: PairedControlCredentials) {
    UserDefaults.standard.set(credentials.deviceID, forKey: "AgentSessionControl.pairedDeviceID")
    let store = KeychainPairedControlCredentialStore()
    try? store.store(credentials)
}

private func clearStoredCredentials() {
    if let deviceID = UserDefaults.standard.string(forKey: "AgentSessionControl.pairedDeviceID") {
        let store = KeychainPairedControlCredentialStore()
        try? store.delete(deviceID: deviceID)
    }
    UserDefaults.standard.removeObject(forKey: "AgentSessionControl.pairedDeviceID")
}

// MARK: - Pairing Screen

/// Shows a camera QR scanner and a manual-paste fallback so the owner can pair with the Mac Agent.
/// The scanner requires `NSCameraUsageDescription` in Info.plist and a physical device.
/// The paste fallback works in any build configuration.
struct PairingView: View {
    var localDisconnectWarning: String?
    var onPaired: (PairedControlCredentials) -> Void

    @State private var manualPayload = ""
    @State private var isPairing = false
    @State private var errorText: String?
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Pair with Mac Agent")
                    .font(.title2.bold())

                Text("Open the Mac Agent menu bar app and scan the QR code, or paste the pairing code below.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let localDisconnectWarning {
                    Text(localDisconnectWarning)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }

                Divider().padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Or paste pairing code:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $manualPayload)
                        .frame(height: 80)
                        .font(.caption.monospaced())
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .padding(.horizontal)
                }
                .padding(.horizontal)

                if let err = errorText {
                    Text(err)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .padding(.horizontal)
                }

                Button {
                    Task { await completePairing(payload: manualPayload) }
                } label: {
                    Group {
                        if isPairing {
                            ProgressView()
                        } else {
                            Text("Connect")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .disabled(manualPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPairing)

                Spacer()
            }
            .navigationTitle("Setup")
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { scanned in
                    showScanner = false
                    Task { await completePairing(payload: scanned) }
                }
            }
        }
    }

    private func completePairing(payload: String) async {
        isPairing = true
        errorText = nil
        defer { isPairing = false }

        let service = OwnerDevicePairingService(
            client: HTTPPairingCompletionClient(),
            credentialStore: KeychainPairedControlCredentialStore(),
            ownerDeviceName: UIDevice.current.name,
            ownerDevicePublicKey: "placeholder-public-key"
        )

        do {
            let response = try await service.completePairing(from: payload.trimmingCharacters(in: .whitespacesAndNewlines))
            onPaired(response.credentials)
        } catch OwnerDevicePairingError.pairedTLSRequired {
            errorText = "Pairing requires a secure connection. Ensure the Mac is reachable on the same Wi-Fi."
        } catch {
            errorText = "Pairing failed: \(error)"
        }
    }
}

/// Wraps `DataScannerViewController` as a SwiftUI sheet for QR code scanning.
struct QRScannerSheet: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DataScannerView(onScan: onScan)
                .ignoresSafeArea()
                .navigationTitle("Scan QR Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

/// `UIViewControllerRepresentable` wrapping `DataScannerViewController` for QR scanning.
struct DataScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !hasScanned else { return }
            if let item = addedItems.first, case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                hasScanned = true
                dataScanner.stopScanning()
                onScan(payload)
            }
        }
    }
}

#else
@main
struct iPhoneApp {
    static func main() {
        print("iPhoneApp is available on iOS.")
    }
}
#endif

enum AppTab: String, CaseIterable {
    case claudeCode
    case audit
    case info

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .audit: return "Audit"
        case .info: return "Info"
        }
    }

    var icon: String {
        switch self {
        case .claudeCode: return "terminal"
        case .audit: return "list.bullet.clipboard"
        case .info: return "info.circle"
        }
    }

    var selectedIcon: String {
        switch self {
        case .claudeCode: return "terminal.fill"
        case .audit: return "list.bullet.clipboard.fill"
        case .info: return "info.circle.fill"
        }
    }
}

#if os(iOS)
@MainActor
@Observable
final class PlanningCenteredStore {
    var state: PlanningCenteredState?
    var errorText: String?
    var isLoading = false
    var isAttaching = false
    var isStartingSession = false
    var isStoppingSession = false
    var isSubmittingReply = false
    var isSubmittingApprovalDecision = false
    var isPreparingDraftComment = false
    var isSubmittingDraftCommentDecision = false
    var isDisconnecting = false
    var replyText = ""
    var draftCommentBody = ""
    var isConfirmingUncertainReply = false
    var isConfirmingStop = false
    var approvalDecisionToConfirm: ApprovalRequestDecision?
    var draftCommentDecisionToConfirm: DraftCommentDecision?
    var selectedTab: AppTab = .claudeCode
    /// Sessions visible on the Mac that can be attached to (populated on demand).
    var discoverableSessions: [DiscoverableSession] = []
    var isRefreshingDiscoverable = false
    var isAttachingSession = false
    var sessionAttachError: String?
    private var pollingTask: Task<Void, Never>?

    private let loadState: @Sendable () async throws -> PlanningCenteredState
    private let attachPlanningArtifact: @Sendable (AttachPlanningArtifactRequest) async throws -> PlanningCenteredState
    private let startWrappedSession: @Sendable () async throws -> PlanningCenteredState
    private let stopWrappedSession: @Sendable (StopWrappedSessionRequest) async throws -> PlanningCenteredState
    private let submitPendingInputReply: @Sendable (SubmitPendingInputReplyRequest) async throws -> PlanningCenteredState
    private let submitApprovalDecision: @Sendable (SubmitApprovalDecisionRequest) async throws -> PlanningCenteredState
    private let prepareDraftComment: @Sendable (PrepareDraftCommentRequest) async throws -> PlanningCenteredState
    private let submitDraftCommentDecision: @Sendable (SubmitDraftCommentDecisionRequest) async throws -> PlanningCenteredState
    private let disconnectPairing: @Sendable () async throws -> Void
    private let listDiscoverableSessionsAction: (@Sendable () async throws -> [DiscoverableSession])?
    private let attachSessionAction: (@Sendable (AttachSessionRequest) async throws -> PlanningCenteredState)?

    init(
        loadState: @escaping @Sendable () async throws -> PlanningCenteredState,
        attachPlanningArtifact: @escaping @Sendable (AttachPlanningArtifactRequest) async throws -> PlanningCenteredState,
        startWrappedSession: @escaping @Sendable () async throws -> PlanningCenteredState,
        stopWrappedSession: @escaping @Sendable (StopWrappedSessionRequest) async throws -> PlanningCenteredState,
        submitPendingInputReply: @escaping @Sendable (SubmitPendingInputReplyRequest) async throws -> PlanningCenteredState,
        submitApprovalDecision: @escaping @Sendable (SubmitApprovalDecisionRequest) async throws -> PlanningCenteredState,
        prepareDraftComment: @escaping @Sendable (PrepareDraftCommentRequest) async throws -> PlanningCenteredState,
        submitDraftCommentDecision: @escaping @Sendable (SubmitDraftCommentDecisionRequest) async throws -> PlanningCenteredState,
        disconnectPairing: @escaping @Sendable () async throws -> Void,
        listDiscoverableSessions: (@Sendable () async throws -> [DiscoverableSession])? = nil,
        attachSession: (@Sendable (AttachSessionRequest) async throws -> PlanningCenteredState)? = nil
    ) {
        self.loadState = loadState
        self.attachPlanningArtifact = attachPlanningArtifact
        self.startWrappedSession = startWrappedSession
        self.stopWrappedSession = stopWrappedSession
        self.submitPendingInputReply = submitPendingInputReply
        self.submitApprovalDecision = submitApprovalDecision
        self.prepareDraftComment = prepareDraftComment
        self.submitDraftCommentDecision = submitDraftCommentDecision
        self.disconnectPairing = disconnectPairing
        self.listDiscoverableSessionsAction = listDiscoverableSessions
        self.attachSessionAction = attachSession
    }

    func foregroundSync() async {
        isLoading = true
        defer { isLoading = false }

        do {
            updateState(try await loadState())
            errorText = nil
        } catch {
            errorText = "Foreground Sync failed: \(error)"
        }
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            var consecutiveErrors = 0
            while !Task.isCancelled {
                if let self {
                    await self.pollOnce(consecutiveErrors: consecutiveErrors)
                    consecutiveErrors = self.errorText != nil ? consecutiveErrors + 1 : 0
                }
                // Back off to 5s after 3 consecutive errors to avoid hammering an unreachable host.
                let delay: UInt64 = consecutiveErrors > 3 ? 5_000_000_000 : 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    /// Like `foregroundSync` but suppresses transient errors for the first 2 consecutive failures,
    /// so minor LAN hiccups don't flash an error message.
    private func pollOnce(consecutiveErrors: Int) async {
        do {
            updateState(try await loadState())
            errorText = nil
        } catch {
            if consecutiveErrors >= 2 {
                errorText = "Mac Agent unreachable — \(urlErrorDescription(error) ?? error.localizedDescription)"
            }
            // First 2 failures: clear stale state but don't overwrite existing errorText with a new one.
        }
    }

    private func urlErrorDescription(_ error: Error) -> String? {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .timedOut: return "connection timed out"
        case .cannotConnectToHost: return "cannot connect to host"
        case .networkConnectionLost: return "network connection lost"
        case .notConnectedToInternet: return "not connected to internet"
        default: return nil
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func attach(kind: PlanningArtifact.Kind, reference: String) async {
        isAttaching = true
        defer { isAttaching = false }

        do {
            updateState(try await attachPlanningArtifact(AttachPlanningArtifactRequest(kind: kind, reference: reference)))
            errorText = nil
        } catch let error as ForegroundStateClientError {
            switch error {
            case .requestFailed(_, let message):
                errorText = message
            default:
                errorText = "Planning Artifact attachment failed: \(error)"
            }
        } catch {
            errorText = "Planning Artifact attachment failed: \(error)"
        }
    }

    func startSession() async {
        isStartingSession = true
        defer { isStartingSession = false }

        do {
            updateState(try await startWrappedSession())
            errorText = nil
        } catch let error as ForegroundStateClientError {
            switch error {
            case .requestFailed(_, let message):
                errorText = message
            default:
                errorText = "Wrapped Session start failed: \(error)"
            }
        } catch {
            errorText = "Wrapped Session start failed: \(error)"
        }
    }

    func refreshDiscoverable() async {
        guard let action = listDiscoverableSessionsAction else { return }
        isRefreshingDiscoverable = true
        defer { isRefreshingDiscoverable = false }

        do {
            discoverableSessions = try await action()
            sessionAttachError = nil
        } catch let error as ForegroundStateClientError {
            sessionAttachError = error.localizedDescription
        } catch {
            sessionAttachError = "Session discovery failed: \(error)"
        }
    }

    func attachSession(sessionID: String) async {
        guard let action = attachSessionAction else { return }
        isAttachingSession = true
        defer { isAttachingSession = false }

        do {
            updateState(try await action(AttachSessionRequest(sessionID: sessionID)))
            sessionAttachError = nil
            discoverableSessions = []
        } catch let error as ForegroundStateClientError {
            switch error {
            case .requestFailed(_, let message):
                sessionAttachError = message
            default:
                sessionAttachError = "Session attach failed: \(error)"
            }
        } catch {
            sessionAttachError = "Session attach failed: \(error)"
        }
    }

    func stopSession() async {
        isStoppingSession = true
        defer { isStoppingSession = false }

        do {
            updateState(try await stopWrappedSession(StopWrappedSessionRequest(confirmStop: true)))
            isConfirmingStop = false
            errorText = nil
        } catch let error as ForegroundStateClientError {
            switch error {
            case .requestFailed(_, let message):
                errorText = message
            default:
                errorText = "Wrapped Session stop failed: \(error)"
            }
        } catch {
            errorText = "Wrapped Session stop failed: \(error)"
        }
    }

    /// Submit a reply to Pending Input.
    /// When `text` is provided (choice tap), that text is sent; otherwise `replyText` is used.
    /// The current `requestID` is always included so the Mac can reject stale replies.
    func submitReply(text: String? = nil, confirmUncertainInput: Bool = false) async {
        isSubmittingReply = true
        defer { isSubmittingReply = false }

        let reply = text ?? replyText
        let requestID = state?.pendingInput?.requestID
        do {
            updateState(try await submitPendingInputReply(
                SubmitPendingInputReplyRequest(
                    reply: reply,
                    confirmUncertainInput: confirmUncertainInput,
                    requestID: requestID
                )
            ))
            if text == nil { replyText = "" }
            errorText = nil
        } catch let error as ForegroundStateClientError {
            switch error {
            case .requestFailed(_, let message):
                errorText = message
            default:
                errorText = "Pending Input reply failed: \(error)"
            }
        } catch {
            errorText = "Pending Input reply failed: \(error)"
        }
    }

    func decideApproval(_ decision: ApprovalRequestDecision, requestID: String) async {
        isSubmittingApprovalDecision = true
        defer { isSubmittingApprovalDecision = false }

        do {
            updateState(try await submitApprovalDecision(
                SubmitApprovalDecisionRequest(requestID: requestID, decision: decision)
            ))
            approvalDecisionToConfirm = nil
            errorText = nil
        } catch let error as ForegroundStateClientError {
            switch error {
            case .requestFailed(_, let message):
                errorText = message
            default:
                errorText = "Approval decision failed: \(error)"
            }
        } catch {
            errorText = "Approval decision failed: \(error)"
        }
    }

    func prepareDraft() async {
        isPreparingDraftComment = true
        defer { isPreparingDraftComment = false }

        do {
            updateState(try await prepareDraftComment(PrepareDraftCommentRequest(forceRegenerate: true)))
            errorText = nil
        } catch let error as ForegroundStateClientError {
            switch error {
            case .requestFailed(_, let message):
                errorText = message
            default:
                errorText = "Draft Comment preparation failed: \(error)"
            }
        } catch {
            errorText = "Draft Comment preparation failed: \(error)"
        }
    }

    func decideDraftComment(_ decision: DraftCommentDecision, draftID: String) async {
        isSubmittingDraftCommentDecision = true
        defer { isSubmittingDraftCommentDecision = false }

        do {
            let request = SubmitDraftCommentDecisionRequest(
                draftID: draftID,
                decision: decision,
                approvedBody: decision == .approve ? draftCommentBody : nil
            )
            updateState(try await submitDraftCommentDecision(request))
            draftCommentDecisionToConfirm = nil
            errorText = nil
        } catch let error as ForegroundStateClientError {
            switch error {
            case .requestFailed(_, let message):
                errorText = message
            default:
                errorText = "Draft Comment decision failed: \(error)"
            }
        } catch {
            errorText = "Draft Comment decision failed: \(error)"
        }
    }

    func disconnect() async throws {
        isDisconnecting = true
        defer { isDisconnecting = false }

        do {
            try await disconnectPairing()
            errorText = nil
        } catch {
            errorText = "Disconnect failed: \(error)"
            throw error
        }
    }

    private func updateState(_ nextState: PlanningCenteredState) {
        state = nextState
        if let draftComment = nextState.draftComment {
            draftCommentBody = draftComment.body
        } else {
            draftCommentBody = ""
            draftCommentDecisionToConfirm = nil
        }
    }
}

/// Caches the resolved `HTTPForegroundStateClient` for the lifetime of a foreground session.
/// Resolves via Bonjour once per session; falls back to the stored URL when unavailable.
/// Invalidated on `URLError` (the Mac's IP may have changed) so the next call re-resolves.
private actor ForegroundClientCache {
    private var _client: HTTPForegroundStateClient?
    private let credentials: PairedControlCredentials

    init(credentials: PairedControlCredentials) {
        self.credentials = credentials
    }

    func client() async throws -> HTTPForegroundStateClient {
        if let cached = _client { return cached }
        let fresh = try await build()
        _client = fresh
        return fresh
    }

    func invalidate() {
        _client = nil
    }

    private func build() async throws -> HTTPForegroundStateClient {
        let baseURL: URL
        if let name = credentials.bonjourServiceName,
           let resolved = try? await BonjourResolver.resolve(serviceName: name) {
            baseURL = resolved
        } else {
            baseURL = credentials.controlBaseURL
        }
        let session: URLSession
        if let fp = credentials.certFingerprintSHA256 {
            session = pinnedURLSession(certFingerprintSHA256: fp)
        } else {
            session = .shared
        }
        return HTTPForegroundStateClient(baseURL: baseURL, credentials: credentials, session: session)
    }
}

extension PlanningCenteredStore {
    /// Builds a store wired to the paired Mac Agent.
    /// The Bonjour URL is resolved once per foreground session and reused for all polls.
    /// On `URLError` the cache is invalidated so the next request re-resolves.
    static func pairedAPI(credentials: PairedControlCredentials) -> PlanningCenteredStore {
        let cache = ForegroundClientCache(credentials: credentials)

        @Sendable func resolvedClient() async throws -> HTTPForegroundStateClient {
            do {
                return try await cache.client()
            } catch {
                await cache.invalidate()
                throw error
            }
        }

        @Sendable func invalidatingClient<T>(_ work: (HTTPForegroundStateClient) async throws -> T) async throws -> T {
            let client = try await resolvedClient()
            do {
                return try await work(client)
            } catch {
                if error is URLError { await cache.invalidate() }
                throw error
            }
        }

        return PlanningCenteredStore {
            try await invalidatingClient { try await ForegroundStateLoader(client: $0).load() }
        } attachPlanningArtifact: { request in
            try await invalidatingClient {
                try PlanningStateMapper().map(try await $0.attachPlanningArtifact(request).foregroundState)
            }
        } startWrappedSession: {
            try await invalidatingClient {
                try PlanningStateMapper().map(try await $0.startWrappedSession().foregroundState)
            }
        } stopWrappedSession: { request in
            try await invalidatingClient {
                try PlanningStateMapper().map(try await $0.stopWrappedSession(request).foregroundState)
            }
        } submitPendingInputReply: { request in
            try await invalidatingClient {
                try PlanningStateMapper().map(try await $0.submitPendingInputReply(request).foregroundState)
            }
        } submitApprovalDecision: { request in
            try await invalidatingClient {
                try PlanningStateMapper().map(try await $0.submitApprovalDecision(request).foregroundState)
            }
        } prepareDraftComment: { request in
            try await invalidatingClient {
                try PlanningStateMapper().map(try await $0.prepareDraftComment(request).foregroundState)
            }
        } submitDraftCommentDecision: { request in
            try await invalidatingClient {
                try PlanningStateMapper().map(try await $0.submitDraftCommentDecision(request).foregroundState)
            }
        } disconnectPairing: {
            try await invalidatingClient {
                try await $0.revokePairing()
                clearStoredCredentials()
            }
        } listDiscoverableSessions: {
            try await invalidatingClient {
                try await $0.listDiscoverableSessions().sessions
            }
        } attachSession: { request in
            try await invalidatingClient {
                try PlanningStateMapper().map(try await $0.attachSession(request).foregroundState)
            }
        }
    }
}

struct PlanningCenteredRootView: View {
    @State private var loader: PlanningCenteredStore
    let credentials: PairedControlCredentials
    let onDisconnected: () -> Void
    let onLocalDisconnect: (String) -> Void

    init(
        loader: PlanningCenteredStore,
        credentials: PairedControlCredentials,
        onDisconnected: @escaping () -> Void,
        onLocalDisconnect: @escaping (String) -> Void
    ) {
        _loader = State(wrappedValue: loader)
        self.credentials = credentials
        self.onDisconnected = onDisconnected
        self.onLocalDisconnect = onLocalDisconnect
    }

    var body: some View {
        RootTabView(
            loader: loader,
            credentials: credentials,
            onDisconnected: onDisconnected,
            onLocalDisconnect: onLocalDisconnect
        )
    }
}

// MARK: - Tab Root

struct RootTabView: View {
    @Bindable var loader: PlanningCenteredStore
    let credentials: PairedControlCredentials
    let onDisconnected: () -> Void
    let onLocalDisconnect: (String) -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch loader.selectedTab {
                case .claudeCode:
                    ClaudeCodeTab(loader: loader)
                case .audit:
                    AuditTab(loader: loader)
                case .info:
                    InfoTab(
                        loader: loader,
                        credentials: credentials,
                        onDisconnected: onDisconnected,
                        onLocalDisconnect: onLocalDisconnect
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selectedTab: $loader.selectedTab)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        .task {
            await loader.foregroundSync()
            loader.startPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                loader.startPolling()
            } else {
                loader.stopPolling()
            }
        }
        .onDisappear {
            loader.stopPolling()
        }
    }
}

// MARK: - Floating Tab Bar

struct FloatingTabBar: View {
    @Binding var selectedTab: AppTab
    @Namespace private var tabNamespace

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
        }
    }

    private func tabButton(_ tab: AppTab) -> some View {
        Button {
            withAnimation(.agentSpring) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: selectedTab == tab ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 20, weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tab ? Color.agentGreen : Color.secondary)
                Text(tab.title)
                    .font(.caption2.weight(selectedTab == tab ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tab ? Color.agentGreen : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Claude Code Tab

struct ClaudeCodeTab: View {
    @Bindable var loader: PlanningCenteredStore

    var body: some View {
        NavigationStack {
            ZStack {
                GlassTabBackground()

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let state = loader.state, let session = state.attachedSession {
                            // Attached: header → attention → file changes
                            sessionHeaderSection(session, actions: state.structuredActions)
                            if let pendingInput = state.pendingInput {
                                PendingInputCard(pendingInput: pendingInput, loader: loader)
                            }
                            if let approval = state.pendingApprovalRequest {
                                approvalSection(approval)
                            }
                            let agentFiles = state.fileReview.files.filter { $0.ownershipTitle != "Pre-existing" }
                            if !agentFiles.isEmpty {
                                FileReviewSection(summary: FileReviewSummary(
                                    title: state.fileReview.title,
                                    detail: state.fileReview.detail,
                                    changedFileCount: agentFiles.count,
                                    preExistingChangeCount: 0,
                                    agentSessionChangeCount: state.fileReview.agentSessionChangeCount,
                                    files: agentFiles
                                ))
                            }
                        } else {
                            // No session: only the session picker
                            AgentSessionSection(session: nil, loader: loader)
                            if let err = loader.errorText {
                                GlassSection("Error") {
                                    Text(err)
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(Color.agentError)
                                        .textSelection(.enabled)
                                        .lineLimit(nil)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 100) // clearance for floating tab bar
                }
                .refreshable {
                    await loader.foregroundSync()
                }
            }
            .navigationTitle("Claude Code")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }

    @ViewBuilder
    private func sessionHeaderSection(_ session: AttachedSessionSummary, actions: [StructuredActionSummary]) -> some View {
        GlassSection {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(sessionStatusColor(session.stateText))
                                .frame(width: 7, height: 7)
                            Text(session.stateText)
                                .font(.subheadline)
                                .foregroundStyle(sessionStatusColor(session.stateText))
                        }
                    }
                    Spacer()
                    if let stop = actions.first(where: { $0.id == "guarded-stop" }), stop.isAvailable {
                        Button(role: .destructive) {
                            loader.isConfirmingStop = true
                        } label: {
                            Image(systemName: "stop.circle")
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.agentError)
                        .disabled(loader.isStoppingSession)
                        .confirmationDialog(
                            "Stop active Wrapped Session?",
                            isPresented: $loader.isConfirmingStop,
                            titleVisibility: .visible
                        ) {
                            Button("Stop Session", role: .destructive) {
                                Task { await loader.stopSession() }
                            }
                            Button("Cancel", role: .cancel) { loader.isConfirmingStop = false }
                        }
                    }
                }
                Text(session.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let tmuxCmd = session.tmuxAttachCommand {
                    Text(tmuxCmd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                if let baseline = session.baselineSummary {
                    Text(baseline)
                        .font(.caption)
                        .foregroundStyle(session.baselineIsDirty ? Color.agentWarning : .secondary)
                }
            }
        }
    }

    private func sessionStatusColor(_ stateText: String) -> Color {
        switch stateText {
        case "Running":
            return Color.agentGreen
        case "Waiting for Input", "Waiting for Approval":
            return Color.agentWarning
        case "Failed to Stop":
            return Color.agentError
        default:
            return Color.secondary
        }
    }

    @ViewBuilder
    private func approvalSection(_ approval: ApprovalRequestSummary) -> some View {
        GlassSection("Approval Required") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Action Requested", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.agentWarning)
                Text(approval.title)
                    .font(.body)
                Text(approval.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        loader.approvalDecisionToConfirm = .approve
                    } label: {
                        Label("Approve", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(loader.isSubmittingApprovalDecision)

                    Button(role: .destructive) {
                        loader.approvalDecisionToConfirm = .deny
                    } label: {
                        Label("Deny", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(loader.isSubmittingApprovalDecision)
                }
            }
        }
        .confirmationDialog(
            "Send approval decision?",
            isPresented: Binding(
                get: { loader.approvalDecisionToConfirm != nil },
                set: { if !$0 { loader.approvalDecisionToConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let decision = loader.approvalDecisionToConfirm {
                Button(decision == .approve ? "Approve" : "Deny", role: decision == .deny ? .destructive : nil) {
                    Task { await loader.decideApproval(decision, requestID: approval.id) }
                }
            }
            Button("Cancel", role: .cancel) { loader.approvalDecisionToConfirm = nil }
        }
    }

    @ViewBuilder
    private func prepareDraftSection(_ action: StructuredActionSummary) -> some View {
        GlassSection("Draft Comment") {
            VStack(alignment: .leading, spacing: 8) {
                Text(action.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await loader.prepareDraft() }
                } label: {
                    Label("Prepare Draft", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.glass)
                .disabled(loader.isPreparingDraftComment)
            }
        }
    }

    @ViewBuilder
    private func draftCommentSection(_ draft: DraftCommentSummary) -> some View {
        GlassSection("Draft Comment") {
            VStack(alignment: .leading, spacing: 8) {
                Text(draft.title).font(.body)
                Text(draft.statusText).font(.caption).foregroundStyle(.secondary)
                TextField("Draft Comment", text: $loader.draftCommentBody, axis: .vertical)
                    .font(.caption)
                    .lineLimit(6...12)
                if let failure = draft.failureMessage {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button {
                        loader.draftCommentDecisionToConfirm = .approve
                    } label: {
                        Label("Post", systemImage: "paperplane.fill")
                    }
                    .disabled(!draft.requiresApproval || loader.draftCommentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loader.isSubmittingDraftCommentDecision)

                    Button(role: .destructive) {
                        loader.draftCommentDecisionToConfirm = .reject
                    } label: {
                        Label("Reject", systemImage: "xmark.circle.fill")
                    }
                    .disabled(!draft.requiresApproval || loader.isSubmittingDraftCommentDecision)
                }
            }
        }
        .confirmationDialog(
            "Decide Draft Comment?",
            isPresented: Binding(
                get: { loader.draftCommentDecisionToConfirm != nil },
                set: { if !$0 { loader.draftCommentDecisionToConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let decision = loader.draftCommentDecisionToConfirm {
                Button(decision == .approve ? "Post to GitHub" : "Reject", role: decision == .reject ? .destructive : nil) {
                    Task { await loader.decideDraftComment(decision, draftID: draft.id) }
                }
            }
            Button("Cancel", role: .cancel) { loader.draftCommentDecisionToConfirm = nil }
        }
    }

    @ViewBuilder
    private func guardedStopSection(_ actions: [StructuredActionSummary]) -> some View {
        if let stop = actions.first(where: { $0.id == "guarded-stop" }), stop.isAvailable {
            GlassSection {
                Button(role: .destructive) {
                    loader.isConfirmingStop = true
                } label: {
                    Label("Stop Agent Session", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.glassProminent)
                .disabled(loader.isStoppingSession)
                .confirmationDialog(
                    "Stop active Wrapped Session?",
                    isPresented: $loader.isConfirmingStop,
                    titleVisibility: .visible
                ) {
                    Button("Stop Session", role: .destructive) {
                        Task { await loader.stopSession() }
                    }
                    Button("Cancel", role: .cancel) { loader.isConfirmingStop = false }
                }
            }
        }
    }
}

// MARK: - Pending Input Card

struct PendingInputCard: View {
    let pendingInput: PendingInputState
    @Bindable var loader: PlanningCenteredStore

    var isUncertain: Bool { pendingInput.status == .uncertain }

    var body: some View {
        GlassSection("Pending Input") {
            VStack(alignment: .leading, spacing: 12) {
                Label(isUncertain ? "Uncertain Input" : "Claude is waiting",
                      systemImage: isUncertain ? "questionmark.bubble.fill" : "bubble.left.and.exclamationmark.bubble.right.fill")
                    .font(.headline)
                    .foregroundStyle(isUncertain ? Color.agentWarning : Color.agentGreen)

                if isUncertain {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.orange)
                        Text("Uncertain Pending Input — confirm before replying")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let prompt = pendingInput.prompt {
                    Text(prompt)
                        .font(.body)
                }

                if !pendingInput.options.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose an answer:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(pendingInput.options) { option in
                            choiceButton(option)
                        }
                    }
                }

                // Free-text reply field (always present as fallback)
                VStack(alignment: .leading, spacing: 6) {
                    if !pendingInput.options.isEmpty {
                        Text("Or type a different reply:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Reply", text: $loader.replyText, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)

                    Button {
                        if isUncertain {
                            loader.isConfirmingUncertainReply = true
                        } else {
                            Task { await loader.submitReply() }
                        }
                    } label: {
                        Label("Send Reply", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(loader.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loader.isSubmittingReply)
                    .confirmationDialog(
                        "Send reply to uncertain Pending Input?",
                        isPresented: $loader.isConfirmingUncertainReply,
                        titleVisibility: .visible
                    ) {
                        Button("Send Reply", role: .destructive) {
                            Task { await loader.submitReply(confirmUncertainInput: true) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func choiceButton(_ option: PendingInputOption) -> some View {
        Button {
            if isUncertain {
                loader.replyText = option.label
                loader.isConfirmingUncertainReply = true
            } else {
                Task { await loader.submitReply(text: option.label) }
            }
        } label: {
            HStack {
                Text(option.label)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(Color.agentGreen)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .disabled(loader.isSubmittingReply)
    }
}

// MARK: - Audit Tab

struct AuditTab: View {
    @Bindable var loader: PlanningCenteredStore

    var body: some View {
        NavigationStack {
            ZStack {
                GlassTabBackground()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let state = loader.state {
                            AuditTimelineSection(summary: state.auditTimeline)
                        } else if let err = loader.errorText {
                            GlassSection("Error") {
                                Text(err)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(Color.agentError)
                                    .textSelection(.enabled)
                            }
                        } else {
                            GlassSection {
                                ContentUnavailableView(
                                    "No Audit Events",
                                    systemImage: "list.bullet.clipboard",
                                    description: Text("Audit events appear once a Wrapped Session starts.")
                                )
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 100)
                }
                .refreshable {
                    await loader.foregroundSync()
                }
            }
            .navigationTitle("Audit")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }
}

// MARK: - Info Tab

struct InfoTab: View {
    @Bindable var loader: PlanningCenteredStore
    let credentials: PairedControlCredentials
    let onDisconnected: () -> Void
    let onLocalDisconnect: (String) -> Void

    var body: some View {
        NavigationStack {
            MacDetailView(
                state: loader.state,
                credentials: credentials,
                loader: loader,
                onDisconnected: onDisconnected,
                onLocalDisconnect: onLocalDisconnect
            )
            .refreshable { await loader.foregroundSync() }
        }
    }
}

struct MacDetailView: View {
    let state: PlanningCenteredState?
    let credentials: PairedControlCredentials
    @Bindable var loader: PlanningCenteredStore
    let onDisconnected: () -> Void
    let onLocalDisconnect: (String) -> Void

    @State private var isConfirmingDisconnect = false
    @State private var isOfferingLocalDisconnect = false

    var body: some View {
        ZStack {
            GlassTabBackground()
            ScrollView {
                LazyVStack(spacing: 12) {
                    GlassSection("Mac") {
                        VStack(spacing: 8) {
                            detailRow(title: "Name", value: state?.macDeviceInfo?.name ?? "Not yet synced")
                            detailRow(title: "macOS", value: state?.macDeviceInfo?.osVersion ?? "Not yet synced")
                            detailRow(title: "Model", value: state?.macDeviceInfo?.modelIdentifier ?? "Not yet synced")
                        }
                    }

                    GlassSection("Repository & Sessions") {
                        VStack(spacing: 8) {
                            detailRow(title: "Repository", value: state?.configuredRepositoryPath ?? "Not yet synced")
                            detailRow(
                                title: "Active Sessions",
                                value: state.map { String($0.activeAttachedSessionCount) } ?? "Not yet synced"
                            )
                        }
                    }

                    GlassSection("Connection") {
                        detailRow(title: "Control API", value: credentials.controlBaseURL.absoluteString)
                    }

                    GlassSection {
                        Button(role: .destructive) {
                            isConfirmingDisconnect = true
                        } label: {
                            Label("Disconnect", systemImage: "bolt.horizontal.circle")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(loader.isDisconnecting)
                    }

                    if let errorText = loader.errorText {
                        GlassSection("Error") {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(Color.agentError)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
        }
        .navigationTitle("Mac")
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .alert("Disconnect from this Mac?", isPresented: $isConfirmingDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task {
                    do {
                        try await loader.disconnect()
                        onDisconnected()
                    } catch {
                        isOfferingLocalDisconnect = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes the Owner Device bearer token on the Mac and removes local credentials.")
        }
        .alert("Mac unreachable", isPresented: $isOfferingLocalDisconnect) {
            Button("Disconnect locally anyway", role: .destructive) {
                onLocalDisconnect("Disconnected locally. The Mac bearer token was not revoked because the Mac was unreachable.")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local credentials will be removed from this iPhone, but the Mac bearer token remains live.")
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}


struct PlanningArtifactSection: View {
    let artifact: PlanningArtifactSummary

    var body: some View {
        GlassSection("Planning Artifact") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: artifact.affordanceTitle == "PR Review" ? "arrow.triangle.pull" : "number")
                        .foregroundStyle(artifact.affordanceTitle == "PR Review" ? Color.agentBlue : Color.agentGreen)
                    Text(artifact.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(artifact.title)
                    .font(.headline)
                Text(artifact.state)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct PlanningArtifactAttachmentSection: View {
    @Bindable var loader: PlanningCenteredStore
    @State private var selectedKind: PlanningArtifact.Kind = .issue
    @State private var reference = ""

    var body: some View {
        GlassSection("Attach Planning Artifact") {
            Picker("Type", selection: $selectedKind) {
                ForEach(PlanningArtifact.Kind.allCases, id: \.rawValue) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            TextField("Issue or PR number or URL", text: $reference)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.bottom, 4)

            Button {
                Task { await loader.attach(kind: selectedKind, reference: reference) }
            } label: {
                Label("Attach", systemImage: "link")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.glass)
            .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loader.isAttaching)
        }
    }
}

struct AgentSessionSection: View {
    let session: AttachedSessionSummary?
    @Bindable var loader: PlanningCenteredStore
    @State private var showPicker = false
    @State private var confirmRewrapID: String?

    var body: some View {
        GlassSection("Session") {
            if let session {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "terminal.fill")
                            .foregroundStyle(Color.agentGreen)
                        Text(session.title)
                            .font(.headline)
                    }
                    Text(session.stateText)
                        .font(.subheadline)
                        .foregroundStyle(Color.agentGreen)
                    Text(session.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let tmuxAttachCommand = session.tmuxAttachCommand {
                        Text(tmuxAttachCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if let baselineSummary = session.baselineSummary {
                        Text(baselineSummary)
                            .font(.caption)
                            .foregroundStyle(session.baselineIsDirty ? Color.agentWarning : .secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                // --- Session picker ---
                if !loader.discoverableSessions.isEmpty {
                    DiscoverableSessionPicker(loader: loader, confirmRewrapID: $confirmRewrapID)
                }

                Button {
                    Task {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                            showPicker = true
                        }
                        await loader.refreshDiscoverable()
                    }
                } label: {
                    if loader.isRefreshingDiscoverable {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Scanning…")
                        }
                    } else {
                        Label("Find Running Sessions", systemImage: "magnifyingglass")
                    }
                }
                .disabled(loader.isRefreshingDiscoverable || loader.isAttachingSession)

                Button {
                    Task { await loader.startSession() }
                } label: {
                    Label("Start New Session", systemImage: "play.fill")
                }
                .disabled(loader.isStartingSession)

                if let attachErr = loader.sessionAttachError {
                    Text(attachErr)
                        .font(.caption)
                        .foregroundStyle(Color.agentError)
                }
            }
        }
        .confirmationDialog(
            "Re-wrap Session?",
            isPresented: Binding(
                get: { confirmRewrapID != nil },
                set: { if !$0 { confirmRewrapID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let id = confirmRewrapID {
                Button("Re-wrap for Full Control") {
                    confirmRewrapID = nil
                    Task { await loader.attachSession(sessionID: id) }
                }
                Button("Cancel", role: .cancel) { confirmRewrapID = nil }
            }
        } message: {
            Text("The running claude process will be restarted with --continue. Conversation history is preserved; terminal scrollback will be lost.")
        }
    }
}

struct DiscoverableSessionPicker: View {
    @Bindable var loader: PlanningCenteredStore
    @Binding var confirmRewrapID: String?

    var body: some View {
        ForEach(loader.discoverableSessions) { discovered in
            Button {
                if discovered.hookWired {
                    Task { await loader.attachSession(sessionID: discovered.id) }
                } else {
                    confirmRewrapID = discovered.id
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: discovered.hookWired ? "checkmark.shield.fill" : "shield")
                        .foregroundStyle(discovered.hookWired ? Color.agentGreen : Color.agentWarning)
                        .font(.system(size: 18))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(discovered.repoPath.isEmpty ? "Unknown directory" : (discovered.repoPath as NSString).lastPathComponent)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(discovered.repoPath.isEmpty ? "" : discovered.repoPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(discovered.kind.badgeTitle)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(discovered.hookWired ? Color.agentGreen.opacity(0.2) : Color.agentWarning.opacity(0.2), in: Capsule())
                                .foregroundStyle(discovered.hookWired ? Color.agentGreen : Color.agentWarning)
                            Text(discovered.lastActivity.relativeDescription)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if loader.isAttachingSession {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loader.isAttachingSession)
        }
    }
}

extension DiscoverableSession.Kind {
    var badgeTitle: String {
        switch self {
        case .agentLaunched: return "FULL CONTROL"
        case .externalTmux: return "RE-WRAP"
        case .bareGhostty: return "BARE · RE-WRAP"
        }
    }
}

extension Date {
    var relativeDescription: String {
        let ago = -timeIntervalSinceNow
        switch ago {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(ago / 60))m ago"
        case ..<86400: return "\(Int(ago / 3600))h ago"
        default: return "\(Int(ago / 86400))d ago"
        }
    }
}


struct PlaceholderSection: View {
    let summary: PlaceholderSummary

    var body: some View {
        GlassSection(summary.title) {
            Text(summary.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct FileReviewSection: View {
    let summary: FileReviewSummary

    var body: some View {
        GlassSection(summary.title) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\(summary.preExistingChangeCount) pre-existing, \(summary.agentSessionChangeCount) Agent Session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            ForEach(summary.files) { file in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path)
                                .font(.subheadline.monospaced())
                            if let previousPath = file.previousPath {
                                Text(previousPath)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(file.changeSize)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(file.ownershipTitle)
                        Text(file.changeKindTitle)
                    }
                    .font(.caption)
                    .foregroundStyle(file.ownershipTitle == "Pre-existing" ? .orange : .blue)

                    Text(file.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !file.riskSignals.isEmpty {
                        Text(file.riskSignals.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ForEach(file.selectedHunks) { hunk in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hunk.header)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(hunk.lines.joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .lineLimit(8)
                                .truncationMode(.middle)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct AuditTimelineSection: View {
    let summary: AuditTimelineSummary

    var body: some View {
        GlassSection(summary.title) {
            if summary.entries.isEmpty {
                Text("No audit events yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.occurredAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(Color.agentGreen.opacity(0.8))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private extension PlanningArtifact.Kind {
    var displayName: String {
        switch self {
        case .issue:
            return "Issue"
        case .pullRequest:
            return "PR"
        }
    }
}
#endif
