import AgentShared
import Foundation
import iPhoneCore
import SwiftUI
#if os(iOS)
import VisionKit
#endif

#if os(iOS)
@main
struct iPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// Top-level view that switches between the pairing screen and the main planning UI.
struct AppRootView: View {
    @State private var credentials: PairedControlCredentials? = loadStoredCredentials()

    var body: some View {
        if let creds = credentials {
            PlanningCenteredRootView(loader: .pairedAPI(credentials: creds))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Unpair") {
                            clearStoredCredentials()
                            credentials = nil
                        }
                    }
                }
        } else {
            PairingView { paired in
                storeCredentials(paired)
                credentials = paired
            }
        }
    }
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
    UserDefaults.standard.removeObject(forKey: "AgentSessionControl.pairedDeviceID")
    // Credentials remain in Keychain (no delete API on the existing store); they'll just be unused.
}

// MARK: - Pairing Screen

/// Shows a camera QR scanner and a manual-paste fallback so the owner can pair with the Mac Agent.
/// The scanner requires `NSCameraUsageDescription` in Info.plist and a physical device.
/// The paste fallback works in any build configuration.
struct PairingView: View {
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
                        .font(.footnote)
                        .foregroundStyle(.red)
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
            errorText = "Pairing failed: \(error.localizedDescription)"
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
    var replyText = ""
    var draftCommentBody = ""
    var isConfirmingUncertainReply = false
    var isConfirmingStop = false
    var approvalDecisionToConfirm: ApprovalRequestDecision?
    var draftCommentDecisionToConfirm: DraftCommentDecision?

    private let loadState: @Sendable () async throws -> PlanningCenteredState
    private let attachPlanningArtifact: @Sendable (AttachPlanningArtifactRequest) async throws -> PlanningCenteredState
    private let startWrappedSession: @Sendable () async throws -> PlanningCenteredState
    private let stopWrappedSession: @Sendable (StopWrappedSessionRequest) async throws -> PlanningCenteredState
    private let submitPendingInputReply: @Sendable (SubmitPendingInputReplyRequest) async throws -> PlanningCenteredState
    private let submitApprovalDecision: @Sendable (SubmitApprovalDecisionRequest) async throws -> PlanningCenteredState
    private let prepareDraftComment: @Sendable (PrepareDraftCommentRequest) async throws -> PlanningCenteredState
    private let submitDraftCommentDecision: @Sendable (SubmitDraftCommentDecisionRequest) async throws -> PlanningCenteredState

    init(
        loadState: @escaping @Sendable () async throws -> PlanningCenteredState,
        attachPlanningArtifact: @escaping @Sendable (AttachPlanningArtifactRequest) async throws -> PlanningCenteredState,
        startWrappedSession: @escaping @Sendable () async throws -> PlanningCenteredState,
        stopWrappedSession: @escaping @Sendable (StopWrappedSessionRequest) async throws -> PlanningCenteredState,
        submitPendingInputReply: @escaping @Sendable (SubmitPendingInputReplyRequest) async throws -> PlanningCenteredState,
        submitApprovalDecision: @escaping @Sendable (SubmitApprovalDecisionRequest) async throws -> PlanningCenteredState,
        prepareDraftComment: @escaping @Sendable (PrepareDraftCommentRequest) async throws -> PlanningCenteredState,
        submitDraftCommentDecision: @escaping @Sendable (SubmitDraftCommentDecisionRequest) async throws -> PlanningCenteredState
    ) {
        self.loadState = loadState
        self.attachPlanningArtifact = attachPlanningArtifact
        self.startWrappedSession = startWrappedSession
        self.stopWrappedSession = stopWrappedSession
        self.submitPendingInputReply = submitPendingInputReply
        self.submitApprovalDecision = submitApprovalDecision
        self.prepareDraftComment = prepareDraftComment
        self.submitDraftCommentDecision = submitDraftCommentDecision
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

    func submitReply(confirmUncertainInput: Bool = false) async {
        isSubmittingReply = true
        defer { isSubmittingReply = false }

        do {
            updateState(try await submitPendingInputReply(
                SubmitPendingInputReplyRequest(
                    reply: replyText,
                    confirmUncertainInput: confirmUncertainInput
                )
            ))
            replyText = ""
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

extension PlanningCenteredStore {
    /// Builds a store wired to the paired Mac Agent.
    /// Uses Bonjour to resolve the current LAN IP at each request, falling back to the stored URL.
    /// When a cert fingerprint is stored, pins the TLS connection to that specific certificate.
    static func pairedAPI(credentials: PairedControlCredentials) -> PlanningCenteredStore {
        func resolvedClient() async throws -> HTTPForegroundStateClient {
            // Resolve via Bonjour if we have a service name; fall back to stored URL.
            let baseURL: URL
            if let name = credentials.bonjourServiceName,
               let resolved = try? await BonjourResolver.resolve(serviceName: name) {
                baseURL = resolved
            } else {
                baseURL = credentials.controlBaseURL
            }

            // Build a cert-pinning URLSession when we have a stored fingerprint.
            let session: URLSession
            if let fp = credentials.certFingerprintSHA256 {
                session = pinnedURLSession(certFingerprintSHA256: fp)
            } else {
                session = .shared
            }

            return HTTPForegroundStateClient(baseURL: baseURL, credentials: credentials, session: session)
        }

        return PlanningCenteredStore {
            let client = try await resolvedClient()
            return try await ForegroundStateLoader(client: client).load()
        } attachPlanningArtifact: { request in
            let client = try await resolvedClient()
            let response = try await client.attachPlanningArtifact(request)
            return try PlanningStateMapper().map(response.foregroundState)
        } startWrappedSession: {
            let client = try await resolvedClient()
            let response = try await client.startWrappedSession()
            return try PlanningStateMapper().map(response.foregroundState)
        } stopWrappedSession: { request in
            let client = try await resolvedClient()
            let response = try await client.stopWrappedSession(request)
            return try PlanningStateMapper().map(response.foregroundState)
        } submitPendingInputReply: { request in
            let client = try await resolvedClient()
            let response = try await client.submitPendingInputReply(request)
            return try PlanningStateMapper().map(response.foregroundState)
        } submitApprovalDecision: { request in
            let client = try await resolvedClient()
            let response = try await client.submitApprovalDecision(request)
            return try PlanningStateMapper().map(response.foregroundState)
        } prepareDraftComment: { request in
            let client = try await resolvedClient()
            let response = try await client.prepareDraftComment(request)
            return try PlanningStateMapper().map(response.foregroundState)
        } submitDraftCommentDecision: { request in
            let client = try await resolvedClient()
            let response = try await client.submitDraftCommentDecision(request)
            return try PlanningStateMapper().map(response.foregroundState)
        }
    }
}

struct PlanningCenteredRootView: View {
    @State private var loader: PlanningCenteredStore

    init(loader: PlanningCenteredStore) {
        _loader = State(wrappedValue: loader)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let state = loader.state {
                    PlanningCenteredView(state: state, loader: loader)
                } else {
                    List {
                        PlanningArtifactAttachmentSection(loader: loader)
                        ContentUnavailableView(
                            "No Foreground State",
                            systemImage: "iphone.and.arrow.forward",
                            description: Text(loader.errorText ?? "Open the app to request the current Planning Artifact and Agent Session.")
                        )
                    }
                }
            }
            .navigationTitle("Planning")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await loader.foregroundSync()
                        }
                    } label: {
                        Label("Foreground Sync", systemImage: "arrow.clockwise")
                    }
                    .disabled(loader.isLoading)
                }
            }
        }
        .task {
            await loader.foregroundSync()
        }
    }
}

struct PlanningCenteredView: View {
    let state: PlanningCenteredState
    let loader: PlanningCenteredStore

    var body: some View {
        List {
            PlanningArtifactAttachmentSection(loader: loader)
            PlanningArtifactSection(artifact: state.activePlanningArtifact)

            AgentSessionSection(session: state.attachedSession, loader: loader)

            StructuredActionsSection(
                actions: state.structuredActions,
                pendingApprovalRequest: state.pendingApprovalRequest,
                draftComment: state.draftComment,
                loader: loader
            )
            FileReviewSection(summary: state.fileReview)
            AuditTimelineSection(summary: state.auditTimeline)
        }
        .listStyle(.insetGrouped)
    }
}

struct PlanningArtifactSection: View {
    let artifact: PlanningArtifactSummary

    var body: some View {
        Section("Planning Artifact") {
            VStack(alignment: .leading, spacing: 6) {
                Text(artifact.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(artifact.affordanceTitle)
                    .font(.subheadline)
                    .foregroundStyle(artifact.affordanceTitle == "PR Review" ? .purple : .blue)
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
        Section("Attach Planning Artifact") {
            Picker("Type", selection: $selectedKind) {
                ForEach(PlanningArtifact.Kind.allCases, id: \.rawValue) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            TextField("Issue or PR number or URL", text: $reference)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task {
                    await loader.attach(kind: selectedKind, reference: reference)
                }
            } label: {
                Label("Attach", systemImage: "link")
            }
            .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loader.isAttaching)
        }
    }
}

struct AgentSessionSection: View {
    let session: AttachedSessionSummary?
    @Bindable var loader: PlanningCenteredStore

    var body: some View {
        Section("Attached Session") {
            if let session {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.title)
                        .font(.headline)
                    Text(session.stateText)
                        .font(.subheadline)
                        .foregroundStyle(.green)
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
                            .foregroundStyle(session.baselineIsDirty ? .orange : .secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    Task {
                        await loader.startSession()
                    }
                } label: {
                    Label("Start Wrapped Session", systemImage: "play.fill")
                }
                .disabled(loader.isStartingSession)
            }
        }
    }
}

struct StructuredActionsSection: View {
    let actions: [StructuredActionSummary]
    let pendingApprovalRequest: ApprovalRequestSummary?
    let draftComment: DraftCommentSummary?
    @Bindable var loader: PlanningCenteredStore

    var body: some View {
        Section("Structured Actions") {
            if let pendingApprovalRequest {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pendingApprovalRequest.title)
                        .font(.body)
                    Text(pendingApprovalRequest.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            loader.approvalDecisionToConfirm = .approve
                        } label: {
                            Label("Approve", systemImage: "checkmark.circle.fill")
                        }
                        .disabled(loader.isSubmittingApprovalDecision)

                        Button(role: .destructive) {
                            loader.approvalDecisionToConfirm = .deny
                        } label: {
                            Label("Deny", systemImage: "xmark.circle.fill")
                        }
                        .disabled(loader.isSubmittingApprovalDecision)
                    }
                }
                .confirmationDialog(
                    "Send approval decision?",
                    isPresented: approvalDecisionConfirmationBinding,
                    titleVisibility: .visible
                ) {
                    if let decision = loader.approvalDecisionToConfirm {
                        Button(decision == .approve ? "Approve" : "Deny", role: decision == .deny ? .destructive : nil) {
                            Task {
                                await loader.decideApproval(decision, requestID: pendingApprovalRequest.id)
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        loader.approvalDecisionToConfirm = nil
                    }
                }
            }

            if let draftComment {
                VStack(alignment: .leading, spacing: 8) {
                    Text(draftComment.title)
                        .font(.body)
                    Text(draftComment.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Draft Comment", text: $loader.draftCommentBody, axis: .vertical)
                        .font(.caption)
                        .lineLimit(6...12)
                    if let failureMessage = draftComment.failureMessage {
                        Text(failureMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Button {
                            loader.draftCommentDecisionToConfirm = .approve
                        } label: {
                            Label("Post", systemImage: "paperplane.fill")
                        }
                        .disabled(
                            !draftComment.requiresApproval
                                || loader.draftCommentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || loader.isSubmittingDraftCommentDecision
                        )

                        Button(role: .destructive) {
                            loader.draftCommentDecisionToConfirm = .reject
                        } label: {
                            Label("Reject", systemImage: "xmark.circle.fill")
                        }
                        .disabled(!draftComment.requiresApproval || loader.isSubmittingDraftCommentDecision)
                    }
                }
                .confirmationDialog(
                    "Decide Draft Comment?",
                    isPresented: draftCommentDecisionConfirmationBinding,
                    titleVisibility: .visible
                ) {
                    if let decision = loader.draftCommentDecisionToConfirm {
                        Button(decision == .approve ? "Post to GitHub" : "Reject", role: decision == .reject ? .destructive : nil) {
                            Task {
                                await loader.decideDraftComment(decision, draftID: draftComment.id)
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        loader.draftCommentDecisionToConfirm = nil
                    }
                }
            }

            ForEach(actions) { action in
                if action.id == "reply", action.isAvailable {
                    VStack(alignment: .leading, spacing: 8) {
                        actionHeader(action)
                        TextField("Reply", text: $loader.replyText, axis: .vertical)
                            .lineLimit(1...4)
                            .textInputAutocapitalization(.sentences)
                        Button {
                            if action.requiresConfirmation {
                                loader.isConfirmingUncertainReply = true
                            } else {
                                Task {
                                    await loader.submitReply()
                                }
                            }
                        } label: {
                            Label("Send Reply", systemImage: "paperplane.fill")
                        }
                        .disabled(loader.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loader.isSubmittingReply)
                        .confirmationDialog(
                            "Send reply to uncertain Pending Input?",
                            isPresented: $loader.isConfirmingUncertainReply,
                            titleVisibility: .visible
                        ) {
                            Button("Send Reply", role: .destructive) {
                                Task {
                                    await loader.submitReply(confirmUncertainInput: true)
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    }
                } else if action.id == "draft-comment" {
                    if draftComment == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            actionHeader(action)
                            Button {
                                Task {
                                    await loader.prepareDraft()
                                }
                            } label: {
                                Label("Prepare Draft", systemImage: "doc.text.magnifyingglass")
                            }
                            .disabled(!action.isAvailable || loader.isPreparingDraftComment)
                        }
                    }
                } else if action.id == "guarded-stop" {
                    if action.isAvailable {
                        VStack(alignment: .leading, spacing: 8) {
                            actionHeader(action)
                            Button(role: .destructive) {
                                loader.isConfirmingStop = true
                            } label: {
                                Label("Stop Session", systemImage: "stop.circle.fill")
                            }
                            .disabled(loader.isStoppingSession)
                            .confirmationDialog(
                                "Stop active Wrapped Session?",
                                isPresented: $loader.isConfirmingStop,
                                titleVisibility: .visible
                            ) {
                                Button("Stop Session", role: .destructive) {
                                    Task {
                                        await loader.stopSession()
                                    }
                                }
                                Button("Cancel", role: .cancel) {
                                    loader.isConfirmingStop = false
                                }
                            }
                        }
                    }
                } else if pendingApprovalRequest == nil || (action.id != "approve" && action.id != "deny") {
                    HStack {
                        actionHeader(action)
                        Spacer()
                        Image(systemName: action.isAvailable ? "checkmark.circle.fill" : "circle.slash")
                            .foregroundStyle(action.isAvailable ? .green : .secondary)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var approvalDecisionConfirmationBinding: Binding<Bool> {
        Binding {
            loader.approvalDecisionToConfirm != nil
        } set: { isPresented in
            if !isPresented {
                loader.approvalDecisionToConfirm = nil
            }
        }
    }

    private var draftCommentDecisionConfirmationBinding: Binding<Bool> {
        Binding {
            loader.draftCommentDecisionToConfirm != nil
        } set: { isPresented in
            if !isPresented {
                loader.draftCommentDecisionToConfirm = nil
            }
        }
    }

    private func actionHeader(_ action: StructuredActionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(action.title)
                .font(.body)
            Text(action.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct PlaceholderSection: View {
    let summary: PlaceholderSummary

    var body: some View {
        Section(summary.title) {
            Text(summary.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct FileReviewSection: View {
    let summary: FileReviewSummary

    var body: some View {
        Section(summary.title) {
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
        Section(summary.title) {
            if summary.entries.isEmpty {
                Text("No audit events yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.body)
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.occurredAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
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
