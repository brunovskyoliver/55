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

public protocol PendingInputSignalAccepting: Sendable {
    func acceptPendingInputSignal(_ signal: PendingInputSignal) throws -> ControlForegroundResponse
}

public protocol PendingInputReplySubmitting: Sendable {
    func submitPendingInputReply(_ request: SubmitPendingInputReplyRequest) throws -> SubmitPendingInputReplyResponse
}

public final class DemoControlService: ControlAPIProviding, PlanningArtifactAttaching, WrappedSessionStarting, PendingInputSignalAccepting, PendingInputReplySubmitting, @unchecked Sendable {
    private let resolver: any PlanningArtifactResolving
    private let baselineCapturer: any WorktreeBaselineCapturing
    private let tmuxLauncher: any TmuxLaunching
    private let inputSender: any WrappedSessionInputSending
    private let sessionIDGenerator: @Sendable () -> String
    private let eventIDGenerator: @Sendable () -> String
    private let now: @Sendable () -> Date
    private let state: LockedDemoControlServiceState

    public init(
        resolver: any PlanningArtifactResolving = GitHubPlanningArtifactResolver(),
        configuredRepositoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        baselineCapturer: any WorktreeBaselineCapturing = GitWorktreeBaselineCapturer(),
        tmuxLauncher: any TmuxLaunching = TmuxClaudeLauncher(),
        inputSender: any WrappedSessionInputSending = TmuxWrappedSessionInputSender(),
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
        self.inputSender = inputSender
        self.sessionIDGenerator = sessionIDGenerator
        self.eventIDGenerator = eventIDGenerator
        self.now = now
        self.state = LockedDemoControlServiceState(
            configuredRepositoryURL: configuredRepositoryURL,
            sessionStore: sessionStore
        )
    }

    public func acceptPendingInputSignal(_ signal: PendingInputSignal) throws -> ControlForegroundResponse {
        try state.acceptPendingInputSignal(
            signal,
            occurredAt: now(),
            eventID: eventIDGenerator()
        )
    }

    public func submitPendingInputReply(_ request: SubmitPendingInputReplyRequest) throws -> SubmitPendingInputReplyResponse {
        let context = try state.preparePendingInputReply(request)
        let attempt = event(
            planningArtifact: context.planningArtifact,
            agentSessionID: context.activeSession.session.id,
            eventType: .structuredActionAttempt,
            title: context.pendingInput.status == .uncertain
                ? "Uncertain Pending Input reply confirmed"
                : "Pending Input reply requested",
            detail: "The Owner Device submitted a guarded reply.",
            metadata: [
                "action": "pending_input_reply",
                "pendingInputStatus": context.pendingInput.status.rawValue
            ]
        )
        try state.append(attempt)

        do {
            try inputSender.sendReply(context.reply, to: context.activeSession)
        } catch let error as PendingInputReplyError {
            try? state.append(
                event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .structuredActionResult,
                    title: "Pending Input reply failed",
                    detail: error.userMessage,
                    metadata: ["action": "pending_input_reply", "result": "failure"]
                )
            )
            throw error
        } catch {
            let replyError = PendingInputReplyError.inputSendFailed(String(describing: error))
            try? state.append(
                event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .structuredActionResult,
                    title: "Pending Input reply failed",
                    detail: replyError.userMessage,
                    metadata: ["action": "pending_input_reply", "result": "failure"]
                )
            )
            throw replyError
        }

        let foregroundState = try state.completePendingInputReply(
            event(
                planningArtifact: context.planningArtifact,
                agentSessionID: context.activeSession.session.id,
                eventType: .structuredActionResult,
                title: "Pending Input reply sent",
                detail: "The guarded reply was delivered to the Wrapped Session.",
                metadata: ["action": "pending_input_reply", "result": "success"]
            )
        )
        return SubmitPendingInputReplyResponse(foregroundState: foregroundState)
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
    private var pendingInput: PendingInputState = .unavailable

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
                activeSession: activeSession,
                pendingInput: pendingInput
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
                activeSession: activeSession,
                pendingInput: pendingInput
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
            pendingInput = .unavailable
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
                activeSession: attachedSession,
                pendingInput: pendingInput
            )
            return StartWrappedSessionResponse(attachedSession: attachedSession, foregroundState: foregroundState)
        }
    }

    func acceptPendingInputSignal(
        _ signal: PendingInputSignal,
        occurredAt: Date,
        eventID: String
    ) throws -> ControlForegroundResponse {
        try lock.withLock {
            guard let activeAttachment, let activeSession else {
                throw PendingInputReplyError.noActiveSession
            }

            let nextPendingInput = nextPendingInputState(from: signal, current: pendingInput, occurredAt: occurredAt)
            pendingInput = nextPendingInput
            self.activeSession = activeSession.withState(
                nextPendingInput.status == .unavailable ? .running : .waitingForInput
            )

            try sessionStore.append(
                SessionEventLogEntry(
                    id: eventID,
                    planningArtifactID: activeAttachment.id,
                    agentSessionID: activeSession.session.id,
                    eventType: .sessionLifecycle,
                    title: lifecycleTitle(for: nextPendingInput),
                    detail: lifecycleDetail(for: nextPendingInput),
                    occurredAt: occurredAt,
                    metadata: [
                        "pendingInputStatus": nextPendingInput.status.rawValue,
                        "pendingInputSource": nextPendingInput.source?.rawValue ?? "none"
                    ]
                )
            )

            return try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: self.activeSession,
                pendingInput: pendingInput
            )
        }
    }

    func preparePendingInputReply(_ request: SubmitPendingInputReplyRequest) throws -> PendingInputReplyContext {
        try lock.withLock {
            guard let activeAttachment, let activeSession else {
                throw PendingInputReplyError.noActiveSession
            }

            let reply = request.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else {
                throw PendingInputReplyError.emptyReply
            }

            guard pendingInput.status != .unavailable else {
                throw PendingInputReplyError.noPendingInput
            }

            if pendingInput.status == .uncertain, !request.confirmUncertainInput {
                throw PendingInputReplyError.uncertainInputRequiresConfirmation
            }

            return PendingInputReplyContext(
                planningArtifact: activeAttachment,
                activeSession: activeSession,
                pendingInput: pendingInput,
                reply: reply
            )
        }
    }

    func completePendingInputReply(_ resultEvent: SessionEventLogEntry) throws -> ControlForegroundResponse {
        try lock.withLock {
            guard let activeAttachment, let activeSession else {
                throw PendingInputReplyError.noActiveSession
            }

            try sessionStore.append(resultEvent)
            pendingInput = .unavailable
            self.activeSession = activeSession.withState(.running)

            return try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: self.activeSession,
                pendingInput: pendingInput
            )
        }
    }

    private func foregroundState(
        for artifact: PlanningArtifact,
        configuredRepository: ConfiguredRepository,
        activeSession: AttachedSession?,
        pendingInput: PendingInputState
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
            pendingInput: pendingInput,
            structuredActionAvailability: StructuredActionAvailability(
                reply: replyActionState(for: pendingInput),
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

    private func nextPendingInputState(
        from signal: PendingInputSignal,
        current: PendingInputState,
        occurredAt: Date
    ) -> PendingInputState {
        switch (signal.source, signal.kind) {
        case (.claudeCodeHook, .detected):
            return PendingInputState(
                status: .hookConfirmed,
                source: .claudeCodeHook,
                prompt: signal.prompt,
                detectedAt: occurredAt
            )
        case (.tmuxHeuristic, .detected):
            guard current.status != .hookConfirmed else {
                return current
            }
            return PendingInputState(
                status: .uncertain,
                source: .tmuxHeuristic,
                prompt: signal.prompt,
                detectedAt: occurredAt
            )
        case (.claudeCodeHook, .cleared):
            return .unavailable
        case (.tmuxHeuristic, .cleared):
            guard current.source == .tmuxHeuristic else {
                return current
            }
            return .unavailable
        }
    }

    private func replyActionState(for pendingInput: PendingInputState) -> StructuredActionState {
        switch pendingInput.status {
        case .unavailable:
            return StructuredActionState(isAvailable: false, reason: "No Pending Input")
        case .hookConfirmed:
            return StructuredActionState(isAvailable: true, reason: "Hook-confirmed Pending Input")
        case .uncertain:
            return StructuredActionState(
                isAvailable: true,
                reason: "Uncertain Pending Input; confirmation required",
                requiresConfirmation: true
            )
        }
    }

    private func lifecycleTitle(for pendingInput: PendingInputState) -> String {
        switch pendingInput.status {
        case .unavailable:
            return "Pending Input cleared"
        case .hookConfirmed:
            return "Pending Input detected"
        case .uncertain:
            return "Uncertain Pending Input detected"
        }
    }

    private func lifecycleDetail(for pendingInput: PendingInputState) -> String {
        switch pendingInput.status {
        case .unavailable:
            return "The Wrapped Session no longer appears to be waiting for input."
        case .hookConfirmed:
            return pendingInput.prompt ?? "Claude Code hook reported Pending Input."
        case .uncertain:
            return pendingInput.prompt ?? "tmux output heuristics suggest Pending Input."
        }
    }
}

private struct WrappedSessionLaunchContext: Sendable {
    var planningArtifact: PlanningArtifact
    var repositoryURL: URL
}

private struct PendingInputReplyContext: Sendable {
    var planningArtifact: PlanningArtifact
    var activeSession: AttachedSession
    var pendingInput: PendingInputState
    var reply: String
}

private extension AttachedSession {
    func withState(_ state: AgentSession.State) -> AttachedSession {
        var nextSession = session
        nextSession.state = state
        return AttachedSession(planningArtifactID: planningArtifactID, session: nextSession)
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
