import AgentShared
import Foundation

public protocol ControlAPIProviding: Sendable {
    func foregroundState() throws -> ControlForegroundResponse
}

public struct DemoControlService: ControlAPIProviding {
    public init() {}

    public func foregroundState() throws -> ControlForegroundResponse {
        Self.seededForegroundState
    }
}

public extension DemoControlService {
    static let seededForegroundState = ControlForegroundResponse(
        planningArtifacts: [
            PlanningArtifact(
                id: "issue-2",
                kind: .issue,
                number: 2,
                title: "Scaffold Apple App Codebase with a demo Control API path",
                url: URL(string: "https://github.com/brunovskyoliver/55/issues/2")!,
                state: "open"
            )
        ],
        activePlanningArtifactID: "issue-2",
        attachedSessions: [
            AttachedSession(
                planningArtifactID: "issue-2",
                session: AgentSession(
                    id: "demo-session-1",
                    displayName: "Demo Agent Session",
                    state: .running,
                    summary: "Foreground Sync is connected to the seeded Mac Agent response."
                )
            )
        ],
        structuredActionAvailability: StructuredActionAvailability(
            reply: StructuredActionState(isAvailable: false, reason: "No Pending Input"),
            approve: StructuredActionState(isAvailable: false, reason: "No approval request"),
            deny: StructuredActionState(isAvailable: false, reason: "No approval request"),
            draftComment: StructuredActionState(isAvailable: false, reason: "Draft Comments arrive in a later slice"),
            guardedStop: StructuredActionState(isAvailable: true, reason: "Demo session is running")
        ),
        fileReview: FileReviewPlaceholder(
            status: "placeholder",
            summary: "File Review will compare the session changes to the Worktree Baseline in a later slice.",
            changedFileCount: 0
        ),
        auditTimeline: AuditTimelinePlaceholder(
            summary: "Audit Timeline placeholder",
            entries: [
                AuditTimelineEntry(
                    id: "event-demo-started",
                    title: "Demo session available",
                    detail: "The Mac Agent is serving one placeholder Planning Artifact.",
                    occurredAt: Date(timeIntervalSince1970: 1_787_771_200)
                )
            ]
        )
    )
}
