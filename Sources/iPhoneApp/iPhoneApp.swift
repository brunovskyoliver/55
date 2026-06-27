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

    private let loadState: @Sendable () async throws -> PlanningCenteredState

    init(loadState: @escaping @Sendable () async throws -> PlanningCenteredState) {
        self.loadState = loadState
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
}

extension PlanningCenteredStore {
    static let localDemoAPI = PlanningCenteredStore {
        let baseURL = URL(string: "http://127.0.0.1:5577")!
        return try await ForegroundStateLoader(client: HTTPForegroundStateClient(baseURL: baseURL)).load()
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
                    PlanningCenteredView(state: state)
                } else {
                    ContentUnavailableView(
                        "No Foreground State",
                        systemImage: "iphone.and.arrow.forward",
                        description: Text(loader.errorText ?? "Open the app to request the current Planning Artifact and Agent Session.")
                    )
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

    var body: some View {
        List {
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
#endif
