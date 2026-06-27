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
    private let eventIDGenerator: @Sendable () -> String
    private let now: @Sendable () -> Date
    private let state: LockedDemoControlServiceState

    public init(
        resolver: any PlanningArtifactResolving = GitHubPlanningArtifactResolver(),
        configuredRepositoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        baselineCapturer: any WorktreeBaselineCapturing = GitWorktreeBaselineCapturer(),
        tmuxLauncher: any TmuxLaunching = TmuxClaudeLauncher(),
        sessionStore: any SessionEventStoring = SQLiteSessionStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appending(path: "AgentSessionControl-\(UUID().uuidString).sqlite")
        ),
        sessionIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        eventIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.baselineCapturer = baselineCapturer
        self.tmuxLauncher = tmuxLauncher
        self.sessionIDGenerator = sessionIDGenerator
        self.eventIDGenerator = eventIDGenerator
        self.now = now
        self.state = LockedDemoControlServiceState(
            configuredRepositoryURL: configuredRepositoryURL,
            sessionStore: sessionStore
        )
    }

    public func foregroundState() throws -> ControlForegroundResponse {
        try state.foregroundState()
    }

    public func attachPlanningArtifact(_ request: AttachPlanningArtifactRequest) throws -> AttachPlanningArtifactResponse {
        let artifact = try resolver.resolve(request)
        let foregroundState = try state.store(
            artifact,
            event: event(
                planningArtifact: artifact,
                eventType: .planningArtifactAttached,
                title: "Planning Artifact attached",
                detail: "\(artifact.kind == .issue ? "Issue" : "Pull Request") #\(artifact.number) is active.",
                metadata: ["source": "gh"]
            )
        )
        return AttachPlanningArtifactResponse(planningArtifact: artifact, foregroundState: foregroundState)
    }

    public func startWrappedSession(_ request: StartWrappedSessionRequest = StartWrappedSessionRequest()) throws -> StartWrappedSessionResponse {
        let launchContext = try state.prepareLaunch()
        let sessionID = sessionIDGenerator()
        try state.append(
            event(
                planningArtifact: launchContext.planningArtifact,
                agentSessionID: sessionID,
                eventType: .structuredActionAttempt,
                title: "Start Wrapped Session requested",
                detail: "The Owner Device requested a Claude Code Wrapped Session.",
                metadata: ["action": "start_wrapped_session"]
            )
        )

        let baseline: WorktreeBaselineSummary
        do {
            baseline = try baselineCapturer.captureBaseline(repositoryURL: launchContext.repositoryURL)
        } catch let error as WrappedSessionLaunchError {
            try? state.append(
                event(
                    planningArtifact: launchContext.planningArtifact,
                    agentSessionID: sessionID,
                    eventType: .structuredActionResult,
                    title: "Start Wrapped Session failed",
                    detail: error.userMessage,
                    metadata: ["action": "start_wrapped_session", "result": "failure"]
                )
            )
            throw error
        } catch {
            let launchError = WrappedSessionLaunchError.baselineCaptureFailed(String(describing: error))
            try? state.append(
                event(
                    planningArtifact: launchContext.planningArtifact,
                    agentSessionID: sessionID,
                    eventType: .structuredActionResult,
                    title: "Start Wrapped Session failed",
                    detail: launchError.userMessage,
                    metadata: ["action": "start_wrapped_session", "result": "failure"]
                )
            )
            throw launchError
        }

        let tmuxAttachment: TmuxAttachmentInfo
        do {
            tmuxAttachment = try tmuxLauncher.launchWrappedSession(
                sessionID: sessionID,
                planningArtifact: launchContext.planningArtifact,
                repositoryURL: launchContext.repositoryURL
            )
        } catch let error as WrappedSessionLaunchError {
            try? state.append(
                event(
                    planningArtifact: launchContext.planningArtifact,
                    agentSessionID: sessionID,
                    eventType: .structuredActionResult,
                    title: "Start Wrapped Session failed",
                    detail: error.userMessage,
                    metadata: ["action": "start_wrapped_session", "result": "failure"]
                )
            )
            throw error
        } catch {
            let launchError = WrappedSessionLaunchError.tmuxLaunchFailed(String(describing: error))
            try? state.append(
                event(
                    planningArtifact: launchContext.planningArtifact,
                    agentSessionID: sessionID,
                    eventType: .structuredActionResult,
                    title: "Start Wrapped Session failed",
                    detail: launchError.userMessage,
                    metadata: ["action": "start_wrapped_session", "result": "failure"]
                )
            )
            throw launchError
        }

        return try state.storeLaunchedSession(
            sessionID: sessionID,
            planningArtifact: launchContext.planningArtifact,
            baseline: baseline,
            tmuxAttachment: tmuxAttachment,
            resultEvent: event(
                planningArtifact: launchContext.planningArtifact,
                agentSessionID: sessionID,
                eventType: .structuredActionResult,
                title: "Start Wrapped Session succeeded",
                detail: "Claude Code is running in tmux session \(tmuxAttachment.sessionName).",
                metadata: ["action": "start_wrapped_session", "result": "success"]
            ),
            lifecycleEvent: event(
                planningArtifact: launchContext.planningArtifact,
                agentSessionID: sessionID,
                eventType: .sessionLifecycle,
                title: "Wrapped Session running",
                detail: baseline.summary,
                metadata: ["state": AgentSession.State.running.rawValue]
            )
        )
    }

    private func event(
        planningArtifact: PlanningArtifact,
        agentSessionID: AgentSession.ID? = nil,
        eventType: SessionEventType,
        title: String,
        detail: String,
        metadata: [String: String] = [:]
    ) -> SessionEventLogEntry {
        SessionEventLogEntry(
            id: eventIDGenerator(),
            planningArtifactID: planningArtifact.id,
            agentSessionID: agentSessionID,
            eventType: eventType,
            title: title,
            detail: detail,
            occurredAt: now(),
            metadata: metadata
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
            summary: "Audit Timeline",
            entries: []
        )
    )
}

private final class LockedDemoControlServiceState: @unchecked Sendable {
    private let lock = NSLock()
    private let configuredRepositoryURL: URL
    private let configuredRepository: ConfiguredRepository
    private let sessionStore: any SessionEventStoring
    private var activeAttachment: PlanningArtifact?
    private var activeSession: AttachedSession?

    init(configuredRepositoryURL: URL, sessionStore: any SessionEventStoring) {
        self.configuredRepositoryURL = configuredRepositoryURL
        self.sessionStore = sessionStore
        self.configuredRepository = ConfiguredRepository(
            id: "configured-repository",
            path: configuredRepositoryURL.path
        )
        self.activeAttachment = DemoControlService.seededForegroundState.planningArtifacts.first
    }

    func foregroundState() throws -> ControlForegroundResponse {
        try lock.withLock {
            guard let activeAttachment else {
                var seededState = DemoControlService.seededForegroundState
                seededState.configuredRepository = configuredRepository
                return seededState
            }

            return try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: activeSession
            )
        }
    }

    func store(_ attachment: PlanningArtifact, event: SessionEventLogEntry) throws -> ControlForegroundResponse {
        try lock.withLock {
            try sessionStore.append(event)
            activeAttachment = attachment
            return try foregroundState(
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

    func append(_ event: SessionEventLogEntry) throws {
        try lock.withLock {
            try sessionStore.append(event)
        }
    }

    func storeLaunchedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        baseline: WorktreeBaselineSummary,
        tmuxAttachment: TmuxAttachmentInfo,
        resultEvent: SessionEventLogEntry,
        lifecycleEvent: SessionEventLogEntry
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
            try sessionStore.append(resultEvent)
            try sessionStore.append(lifecycleEvent)
            activeSession = attachedSession
            let foregroundState = try foregroundState(
                for: planningArtifact,
                configuredRepository: configuredRepository,
                activeSession: attachedSession
            )
            return StartWrappedSessionResponse(attachedSession: attachedSession, foregroundState: foregroundState)
        }
    }

    private func foregroundState(
        for artifact: PlanningArtifact,
        configuredRepository: ConfiguredRepository,
        activeSession: AttachedSession?
    ) throws -> ControlForegroundResponse {
        let attachedSessions = activeSession.map { [$0] } ?? []
        let sessionIsRunning = activeSession?.session.state == .running
        let auditEvents = try sessionStore.query(
            SessionEventQuery(planningArtifactID: artifact.id, limit: 20)
        )

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
                summary: "Audit Timeline",
                entries: auditEvents.map {
                    AuditTimelineEntry(
                        id: $0.id,
                        title: $0.title,
                        detail: $0.detail,
                        occurredAt: $0.occurredAt
                    )
                }
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
