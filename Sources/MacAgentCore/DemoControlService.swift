import AgentShared
import Foundation

public protocol ControlAPIProviding: Sendable {
    func foregroundState() throws -> ControlForegroundResponse
}

public protocol PlanningArtifactAttaching: Sendable {
    func attachPlanningArtifact(_ request: AttachPlanningArtifactRequest) throws -> AttachPlanningArtifactResponse
}

public protocol WrappedSessionStarting: Sendable {
    func startWrappedSession(_ request: StartWrappedSessionRequest) throws -> StartWrappedSessionResponse
}

public final class DemoControlService: ControlAPIProviding, PlanningArtifactAttaching, WrappedSessionStarting, @unchecked Sendable {
    private let resolver: any PlanningArtifactResolving
    private let baselineCapturer: any WorktreeBaselineCapturing
    private let tmuxLauncher: any TmuxLaunching
    private let sessionIDGenerator: @Sendable () -> String
    private let state: LockedDemoControlServiceState

    public init(
        resolver: any PlanningArtifactResolving = GitHubPlanningArtifactResolver(),
        configuredRepositoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        baselineCapturer: any WorktreeBaselineCapturing = GitWorktreeBaselineCapturer(),
        tmuxLauncher: any TmuxLaunching = TmuxClaudeLauncher(),
        sessionIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.resolver = resolver
        self.baselineCapturer = baselineCapturer
        self.tmuxLauncher = tmuxLauncher
        self.sessionIDGenerator = sessionIDGenerator
        self.state = LockedDemoControlServiceState(configuredRepositoryURL: configuredRepositoryURL)
    }

    public func foregroundState() throws -> ControlForegroundResponse {
        state.foregroundState()
    }

    public func attachPlanningArtifact(_ request: AttachPlanningArtifactRequest) throws -> AttachPlanningArtifactResponse {
        let artifact = try resolver.resolve(request)
        let foregroundState = state.store(artifact)
        return AttachPlanningArtifactResponse(planningArtifact: artifact, foregroundState: foregroundState)
    }

    public func startWrappedSession(_ request: StartWrappedSessionRequest = StartWrappedSessionRequest()) throws -> StartWrappedSessionResponse {
        let launchContext = try state.prepareLaunch()
        let baseline: WorktreeBaselineSummary
        do {
            baseline = try baselineCapturer.captureBaseline(repositoryURL: launchContext.repositoryURL)
        } catch let error as WrappedSessionLaunchError {
            throw error
        } catch {
            throw WrappedSessionLaunchError.baselineCaptureFailed(String(describing: error))
        }

        let sessionID = sessionIDGenerator()
        let tmuxAttachment: TmuxAttachmentInfo
        do {
            tmuxAttachment = try tmuxLauncher.launchWrappedSession(
                sessionID: sessionID,
                planningArtifact: launchContext.planningArtifact,
                repositoryURL: launchContext.repositoryURL
            )
        } catch let error as WrappedSessionLaunchError {
            throw error
        } catch {
            throw WrappedSessionLaunchError.tmuxLaunchFailed(String(describing: error))
        }

        return try state.storeLaunchedSession(
            sessionID: sessionID,
            planningArtifact: launchContext.planningArtifact,
            baseline: baseline,
            tmuxAttachment: tmuxAttachment
        )
    }
}

public extension DemoControlService {
    static let seededForegroundState = ControlForegroundResponse(
        configuredRepository: ConfiguredRepository(
            id: "configured-repository",
            path: FileManager.default.currentDirectoryPath
        ),
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
        attachedSessions: [],
        structuredActionAvailability: StructuredActionAvailability(
            reply: StructuredActionState(isAvailable: false, reason: "No Pending Input"),
            approve: StructuredActionState(isAvailable: false, reason: "No approval request"),
            deny: StructuredActionState(isAvailable: false, reason: "No approval request"),
            draftComment: StructuredActionState(isAvailable: false, reason: "Draft Comments arrive in a later slice"),
            guardedStop: StructuredActionState(isAvailable: false, reason: "No Agent Session")
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
    private let configuredRepositoryURL: URL
    private let configuredRepository: ConfiguredRepository
    private var activeAttachment: PlanningArtifact?
    private var activeSession: AttachedSession?

    init(configuredRepositoryURL: URL) {
        self.configuredRepositoryURL = configuredRepositoryURL
        self.configuredRepository = ConfiguredRepository(
            id: "configured-repository",
            path: configuredRepositoryURL.path
        )
        self.activeAttachment = DemoControlService.seededForegroundState.planningArtifacts.first
    }

    func foregroundState() -> ControlForegroundResponse {
        lock.withLock {
            guard let activeAttachment else {
                var seededState = DemoControlService.seededForegroundState
                seededState.configuredRepository = configuredRepository
                return seededState
            }

            return Self.foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: activeSession
            )
        }
    }

    func store(_ attachment: PlanningArtifact) -> ControlForegroundResponse {
        lock.withLock {
            activeAttachment = attachment
            return Self.foregroundState(
                for: attachment,
                configuredRepository: configuredRepository,
                activeSession: activeSession
            )
        }
    }

    func prepareLaunch() throws -> WrappedSessionLaunchContext {
        try lock.withLock {
            guard let activeAttachment else {
                throw WrappedSessionLaunchError.noActivePlanningArtifact
            }

            if let activeSession, activeSession.session.state == .running {
                throw WrappedSessionLaunchError.activeSessionAlreadyRunning(activeSession.session.id)
            }

            return WrappedSessionLaunchContext(
                planningArtifact: activeAttachment,
                repositoryURL: configuredRepositoryURL
            )
        }
    }

    func storeLaunchedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        baseline: WorktreeBaselineSummary,
        tmuxAttachment: TmuxAttachmentInfo
    ) throws -> StartWrappedSessionResponse {
        try lock.withLock {
            if let activeSession, activeSession.session.state == .running {
                throw WrappedSessionLaunchError.activeSessionAlreadyRunning(activeSession.session.id)
            }

            activeAttachment = planningArtifact
            let session = AgentSession(
                id: sessionID,
                displayName: "Claude Code Wrapped Session",
                state: .running,
                summary: baseline.isDirty
                    ? "Running with a dirty Worktree Baseline."
                    : "Running from a clean Worktree Baseline.",
                tmuxAttachment: tmuxAttachment,
                worktreeBaseline: baseline
            )
            let attachedSession = AttachedSession(planningArtifactID: planningArtifact.id, session: session)
            activeSession = attachedSession
            let foregroundState = Self.foregroundState(
                for: planningArtifact,
                configuredRepository: configuredRepository,
                activeSession: attachedSession
            )
            return StartWrappedSessionResponse(attachedSession: attachedSession, foregroundState: foregroundState)
        }
    }

    private static func foregroundState(
        for artifact: PlanningArtifact,
        configuredRepository: ConfiguredRepository,
        activeSession: AttachedSession?
    ) -> ControlForegroundResponse {
        let attachedSessions = activeSession.map { [$0] } ?? []
        let sessionIsRunning = activeSession?.session.state == .running

        return ControlForegroundResponse(
            configuredRepository: configuredRepository,
            planningArtifacts: [artifact],
            activePlanningArtifactID: artifact.id,
            attachedSessions: attachedSessions,
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
                guardedStop: StructuredActionState(
                    isAvailable: sessionIsRunning,
                    reason: sessionIsRunning ? "Wrapped Session is running" : "No Agent Session"
                )
            ),
            fileReview: FileReviewPlaceholder(
                status: "placeholder",
                summary: activeSession?.session.worktreeBaseline?.summary
                    ?? "File Review is unavailable until a Wrapped Session starts.",
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

private struct WrappedSessionLaunchContext: Sendable {
    var planningArtifact: PlanningArtifact
    var repositoryURL: URL
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
