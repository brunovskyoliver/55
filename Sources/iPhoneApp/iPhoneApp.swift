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

    private let loadState: @Sendable () async throws -> PlanningCenteredState
    private let attachPlanningArtifact: @Sendable (AttachPlanningArtifactRequest) async throws -> PlanningCenteredState

    init(
        loadState: @escaping @Sendable () async throws -> PlanningCenteredState,
        attachPlanningArtifact: @escaping @Sendable (AttachPlanningArtifactRequest) async throws -> PlanningCenteredState
    ) {
        self.loadState = loadState
        self.attachPlanningArtifact = attachPlanningArtifact
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

            if let attachedSession = state.attachedSession {
                AgentSessionSection(session: attachedSession)
            }

            StructuredActionsSection(actions: state.structuredActions)
            PlaceholderSection(summary: state.fileReview)
            PlaceholderSection(summary: state.auditTimeline)
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
    let session: AttachedSessionSummary

    var body: some View {
        Section("Attached Session") {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.headline)
                Text(session.stateText)
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text(session.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct StructuredActionsSection: View {
    let actions: [StructuredActionSummary]

    var body: some View {
        Section("Structured Actions") {
            ForEach(actions) { action in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.title)
                            .font(.body)
                        Text(action.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
