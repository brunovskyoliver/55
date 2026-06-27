import AgentShared
import Foundation
import iPhoneCore
import SwiftUI

#if os(iOS)
@main
struct iPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            PlanningCenteredRootView(loader: .localDemoAPI)
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
    var isSubmittingReply = false
    var replyText = ""
    var isConfirmingUncertainReply = false

    private let loadState: @Sendable () async throws -> PlanningCenteredState
    private let attachPlanningArtifact: @Sendable (AttachPlanningArtifactRequest) async throws -> PlanningCenteredState
    private let startWrappedSession: @Sendable () async throws -> PlanningCenteredState
    private let submitPendingInputReply: @Sendable (SubmitPendingInputReplyRequest) async throws -> PlanningCenteredState

    init(
        loadState: @escaping @Sendable () async throws -> PlanningCenteredState,
        attachPlanningArtifact: @escaping @Sendable (AttachPlanningArtifactRequest) async throws -> PlanningCenteredState,
        startWrappedSession: @escaping @Sendable () async throws -> PlanningCenteredState,
        submitPendingInputReply: @escaping @Sendable (SubmitPendingInputReplyRequest) async throws -> PlanningCenteredState
    ) {
        self.loadState = loadState
        self.attachPlanningArtifact = attachPlanningArtifact
        self.startWrappedSession = startWrappedSession
        self.submitPendingInputReply = submitPendingInputReply
    }

    func foregroundSync() async {
        isLoading = true
        defer { isLoading = false }

        do {
            state = try await loadState()
            errorText = nil
        } catch {
            errorText = "Foreground Sync failed: \(error)"
        }
    }

    func attach(kind: PlanningArtifact.Kind, reference: String) async {
        isAttaching = true
        defer { isAttaching = false }

        do {
            state = try await attachPlanningArtifact(AttachPlanningArtifactRequest(kind: kind, reference: reference))
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
            state = try await startWrappedSession()
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

    func submitReply(confirmUncertainInput: Bool = false) async {
        isSubmittingReply = true
        defer { isSubmittingReply = false }

        do {
            state = try await submitPendingInputReply(
                SubmitPendingInputReplyRequest(
                    reply: replyText,
                    confirmUncertainInput: confirmUncertainInput
                )
            )
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
}

extension PlanningCenteredStore {
    static let localDemoAPI = PlanningCenteredStore {
        let baseURL = URL(string: "https://127.0.0.1:5577")!
        let client = HTTPForegroundStateClient(baseURL: baseURL)
        return try await ForegroundStateLoader(client: client).load()
    } attachPlanningArtifact: { request in
        let baseURL = URL(string: "https://127.0.0.1:5577")!
        let client = HTTPForegroundStateClient(baseURL: baseURL)
        let response = try await client.attachPlanningArtifact(request)
        return try PlanningStateMapper().map(response.foregroundState)
    } startWrappedSession: {
        let baseURL = URL(string: "https://127.0.0.1:5577")!
        let client = HTTPForegroundStateClient(baseURL: baseURL)
        let response = try await client.startWrappedSession()
        return try PlanningStateMapper().map(response.foregroundState)
    } submitPendingInputReply: { request in
        let baseURL = URL(string: "https://127.0.0.1:5577")!
        let client = HTTPForegroundStateClient(baseURL: baseURL)
        let response = try await client.submitPendingInputReply(request)
        return try PlanningStateMapper().map(response.foregroundState)
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

            StructuredActionsSection(actions: state.structuredActions, loader: loader)
            PlaceholderSection(summary: state.fileReview)
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
    @Bindable var loader: PlanningCenteredStore

    var body: some View {
        Section("Structured Actions") {
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
                } else {
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
