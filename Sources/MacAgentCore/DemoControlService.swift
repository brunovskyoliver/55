import AgentShared
import Foundation

public protocol ControlAPIProviding: Sendable {
    func foregroundState() throws -> ControlForegroundResponse
}

public protocol PlanningArtifactAttaching: Sendable {
    func attachPlanningArtifact(_ request: AttachPlanningArtifactRequest) throws -> AttachPlanningArtifactResponse
}

public final class DemoControlService: ControlAPIProviding, PlanningArtifactAttaching, @unchecked Sendable {
    private let resolver: any PlanningArtifactResolving
    private let state = LockedDemoControlServiceState()

    public init(resolver: any PlanningArtifactResolving = GitHubPlanningArtifactResolver()) {
        self.resolver = resolver
    }

    public func foregroundState() throws -> ControlForegroundResponse {
        state.foregroundState()
    }

    public func attachPlanningArtifact(_ request: AttachPlanningArtifactRequest) throws -> AttachPlanningArtifactResponse {
        let artifact = try resolver.resolve(request)
        let foregroundState = state.store(artifact)
        return AttachPlanningArtifactResponse(planningArtifact: artifact, foregroundState: foregroundState)
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

private final class LockedDemoControlServiceState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeAttachment: PlanningArtifact?

    func foregroundState() -> ControlForegroundResponse {
        lock.withLock {
            guard let activeAttachment else {
                return DemoControlService.seededForegroundState
            }

            return Self.foregroundState(for: activeAttachment)
        }
    }

    func store(_ attachment: PlanningArtifact) -> ControlForegroundResponse {
        lock.withLock {
            activeAttachment = attachment
            return Self.foregroundState(for: attachment)
        }
    }

    private static func foregroundState(for artifact: PlanningArtifact) -> ControlForegroundResponse {
        ControlForegroundResponse(
            planningArtifacts: [artifact],
            activePlanningArtifactID: artifact.id,
            attachedSessions: [],
            structuredActionAvailability: StructuredActionAvailability(
                reply: StructuredActionState(isAvailable: false, reason: "No Agent Session"),
                approve: StructuredActionState(isAvailable: false, reason: "No approval request"),
                deny: StructuredActionState(isAvailable: false, reason: "No approval request"),
                draftComment: StructuredActionState(
                    isAvailable: artifact.kind == .issue,
                    reason: artifact.kind == .issue
                        ? "Issue planning comment can be prepared in a later slice"
                        : "PR review comments arrive in a later slice"
                ),
                guardedStop: StructuredActionState(isAvailable: false, reason: "No Agent Session")
            ),
            fileReview: FileReviewPlaceholder(
                status: "placeholder",
                summary: "File Review is unavailable until a Wrapped Session starts.",
                changedFileCount: 0
            ),
            auditTimeline: AuditTimelinePlaceholder(
                summary: "Audit Timeline placeholder",
                entries: [
                    AuditTimelineEntry(
                        id: "event-active-artifact-\(artifact.id)",
                        title: "Planning Artifact attached",
                        detail: "\(artifact.kind == .issue ? "Issue" : "Pull Request") #\(artifact.number) is active.",
                        occurredAt: Date(timeIntervalSince1970: 1_787_800_000)
                    )
                ]
            )
        )
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
