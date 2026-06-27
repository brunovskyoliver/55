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

public protocol WrappedSessionStopSubmitting: Sendable {
    func stopWrappedSession(_ request: StopWrappedSessionRequest) throws -> StopWrappedSessionResponse
}

public protocol PendingInputSignalAccepting: Sendable {
    func acceptPendingInputSignal(_ signal: PendingInputSignal) throws -> ControlForegroundResponse
}

public protocol PendingInputReplySubmitting: Sendable {
    func submitPendingInputReply(_ request: SubmitPendingInputReplyRequest) throws -> SubmitPendingInputReplyResponse
}

public protocol ApprovalRequestSignalAccepting: Sendable {
    func acceptApprovalRequestSignal(_ signal: ApprovalRequestSignal) throws -> ControlForegroundResponse
}

public protocol ApprovalDecisionSubmitting: Sendable {
    func submitApprovalDecision(_ request: SubmitApprovalDecisionRequest) throws -> SubmitApprovalDecisionResponse
}

public protocol DraftCommentPreparing: Sendable {
    func prepareDraftComment(_ request: PrepareDraftCommentRequest) throws -> PrepareDraftCommentResponse
}

public protocol DraftCommentDecisionSubmitting: Sendable {
    func submitDraftCommentDecision(_ request: SubmitDraftCommentDecisionRequest) throws -> SubmitDraftCommentDecisionResponse
}

public final class DemoControlService: ControlAPIProviding, PlanningArtifactAttaching, WrappedSessionStarting, WrappedSessionStopSubmitting, PendingInputSignalAccepting, PendingInputReplySubmitting, ApprovalRequestSignalAccepting, ApprovalDecisionSubmitting, DraftCommentPreparing, DraftCommentDecisionSubmitting, @unchecked Sendable {
    private let resolver: any PlanningArtifactResolving
    private let baselineCapturer: any WorktreeBaselineCapturing
    private let tmuxLauncher: any TmuxLaunching
    private let transcriptCapturer: (any WrappedSessionTranscriptCapturing)?
    private let sessionStopper: any WrappedSessionStopping
    private let inputSender: any WrappedSessionInputSending
    private let approvalDecisionSender: any ApprovalDecisionSending
    private let commentPoster: any GitHubCommentPosting
    private let sessionIDGenerator: @Sendable () -> String
    private let draftIDGenerator: @Sendable () -> String
    private let eventIDGenerator: @Sendable () -> String
    private let now: @Sendable () -> Date
    private let state: LockedDemoControlServiceState

    public init(
        resolver: any PlanningArtifactResolving = GitHubPlanningArtifactResolver(),
        configuredRepositoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        baselineCapturer: any WorktreeBaselineCapturing = GitWorktreeBaselineCapturer(),
        tmuxLauncher: any TmuxLaunching = TmuxClaudeLauncher(),
        transcriptCapturer: (any WrappedSessionTranscriptCapturing)? = nil,
        sessionStopper: any WrappedSessionStopping = TmuxWrappedSessionStopper(),
        inputSender: any WrappedSessionInputSending = TmuxWrappedSessionInputSender(),
        approvalDecisionSender: any ApprovalDecisionSending = TmuxApprovalDecisionSender(),
        commentPoster: any GitHubCommentPosting = GitHubCLICommentPoster(),
        fileReviewBuilder: any FileReviewBuilding = GitFileReviewBuilder(),
        sessionStore: any SessionEventStoring = SQLiteSessionStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appending(path: "AgentSessionControl-\(UUID().uuidString).sqlite")
        ),
        sessionIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        draftIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        eventIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.baselineCapturer = baselineCapturer
        self.tmuxLauncher = tmuxLauncher
        if let transcriptCapturer {
            self.transcriptCapturer = transcriptCapturer
        } else if let transcriptMetadataStore = sessionStore as? any TranscriptMetadataStoring {
            self.transcriptCapturer = TmuxWrappedSessionTranscriptCapturer(
                transcriptStore: LocalTranscriptFileStore.applicationSupportStore(metadataStore: transcriptMetadataStore)
            )
        } else {
            self.transcriptCapturer = nil
        }
        self.sessionStopper = sessionStopper
        self.inputSender = inputSender
        self.approvalDecisionSender = approvalDecisionSender
        self.commentPoster = commentPoster
        self.sessionIDGenerator = sessionIDGenerator
        self.draftIDGenerator = draftIDGenerator
        self.eventIDGenerator = eventIDGenerator
        self.now = now
        self.state = LockedDemoControlServiceState(
            configuredRepositoryURL: configuredRepositoryURL,
            sessionStore: sessionStore,
            fileReviewBuilder: fileReviewBuilder
        )
    }

    public func prepareDraftComment(_ request: PrepareDraftCommentRequest = PrepareDraftCommentRequest()) throws -> PrepareDraftCommentResponse {
        try state.prepareDraftComment(
            draftID: draftIDGenerator(),
            preparedAt: now(),
            eventID: eventIDGenerator()
        )
    }

    public func submitDraftCommentDecision(_ request: SubmitDraftCommentDecisionRequest) throws -> SubmitDraftCommentDecisionResponse {
        let context = try state.prepareDraftCommentDecision(request)
        let attemptTitle = context.decision == .approve
            ? "Draft Comment approved"
            : "Draft Comment rejected"
        try state.append(
            event(
                planningArtifact: context.planningArtifact,
                agentSessionID: context.activeSession?.session.id,
                eventType: .structuredActionAttempt,
                title: attemptTitle,
                detail: context.draft.title,
                metadata: [
                    "action": "draft_comment_decision",
                    "draftCommentID": context.draft.id,
                    "decision": context.decision.rawValue
                ]
            )
        )

        guard context.decision == .approve else {
            let foregroundState = try state.completeDraftCommentRejection(
                draftID: context.draft.id,
                resultEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession?.session.id,
                    eventType: .structuredActionResult,
                    title: "Draft Comment rejected",
                    detail: "The Draft Comment was rejected by the Owner Device and was not posted.",
                    metadata: [
                        "action": "draft_comment_decision",
                        "draftCommentID": context.draft.id,
                        "decision": DraftCommentDecision.reject.rawValue,
                        "result": "rejected"
                    ]
                )
            )
            return SubmitDraftCommentDecisionResponse(foregroundState: foregroundState)
        }

        do {
            let result = try commentPoster.postGeneralComment(context.commentBody, to: context.planningArtifact)
            let foregroundState = try state.completeDraftCommentPost(
                draftID: context.draft.id,
                postedBody: context.commentBody,
                resultEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession?.session.id,
                    eventType: .githubAction,
                    title: "GitHub comment posted",
                    detail: result.summary,
                    metadata: [
                        "action": "github_comment_post",
                        "draftCommentID": context.draft.id,
                        "result": "success",
                        "url": result.url?.absoluteString ?? ""
                    ]
                )
            )
            return SubmitDraftCommentDecisionResponse(foregroundState: foregroundState)
        } catch let error as DraftCommentError {
            try? state.completeDraftCommentFailure(
                draftID: context.draft.id,
                message: error.userMessage,
                resultEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession?.session.id,
                    eventType: .githubAction,
                    title: "GitHub comment post failed",
                    detail: error.userMessage,
                    metadata: [
                        "action": "github_comment_post",
                        "draftCommentID": context.draft.id,
                        "result": "failure"
                    ]
                )
            )
            throw error
        } catch {
            let draftError = DraftCommentError.githubPostFailed(String(describing: error))
            try? state.completeDraftCommentFailure(
                draftID: context.draft.id,
                message: draftError.userMessage,
                resultEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession?.session.id,
                    eventType: .githubAction,
                    title: "GitHub comment post failed",
                    detail: draftError.userMessage,
                    metadata: [
                        "action": "github_comment_post",
                        "draftCommentID": context.draft.id,
                        "result": "failure"
                    ]
                )
            )
            throw draftError
        }
    }

    public func acceptPendingInputSignal(_ signal: PendingInputSignal) throws -> ControlForegroundResponse {
        try state.acceptPendingInputSignal(
            signal,
            occurredAt: now(),
            eventID: eventIDGenerator()
        )
    }

    public func acceptApprovalRequestSignal(_ signal: ApprovalRequestSignal) throws -> ControlForegroundResponse {
        try state.acceptApprovalRequestSignal(
            signal,
            occurredAt: now(),
            eventID: eventIDGenerator()
        )
    }

    public func submitApprovalDecision(_ request: SubmitApprovalDecisionRequest) throws -> SubmitApprovalDecisionResponse {
        let context = try state.prepareApprovalDecision(request)
        let attemptTitle = context.decision == .approve
            ? "Approval request approved"
            : "Approval request denied"
        try state.append(
            event(
                planningArtifact: context.planningArtifact,
                agentSessionID: context.activeSession.session.id,
                eventType: .structuredActionAttempt,
                title: attemptTitle,
                detail: context.approvalRequest.title,
                metadata: [
                    "action": "approval_decision",
                    "approvalRequestID": context.approvalRequest.requestID,
                    "decision": context.decision.rawValue
                ]
            )
        )

        do {
            try approvalDecisionSender.sendApprovalDecision(context.decision, to: context.activeSession)
        } catch let error as ApprovalDecisionError {
            try? state.append(
                event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .structuredActionResult,
                    title: "Approval decision failed",
                    detail: error.userMessage,
                    metadata: ["action": "approval_decision", "result": "failure"]
                )
            )
            throw error
        } catch {
            let decisionError = ApprovalDecisionError.decisionSendFailed(String(describing: error))
            try? state.append(
                event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .structuredActionResult,
                    title: "Approval decision failed",
                    detail: decisionError.userMessage,
                    metadata: ["action": "approval_decision", "result": "failure"]
                )
            )
            throw decisionError
        }

        let foregroundState = try state.completeApprovalDecision(
            requestID: context.approvalRequest.requestID,
            resultEvent: event(
                planningArtifact: context.planningArtifact,
                agentSessionID: context.activeSession.session.id,
                eventType: .structuredActionResult,
                title: context.decision == .approve
                    ? "Approval decision delivered"
                    : "Denial decision delivered",
                detail: "The \(context.decision.rawValue) decision was delivered to the Wrapped Session.",
                metadata: [
                    "action": "approval_decision",
                    "approvalRequestID": context.approvalRequest.requestID,
                    "decision": context.decision.rawValue,
                    "result": "success"
                ]
            )
        )
        return SubmitApprovalDecisionResponse(foregroundState: foregroundState)
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

    public func stopWrappedSession(_ request: StopWrappedSessionRequest) throws -> StopWrappedSessionResponse {
        let context = try state.prepareStop(request)
        try state.append(
            event(
                planningArtifact: context.planningArtifact,
                agentSessionID: context.activeSession.session.id,
                eventType: .structuredActionAttempt,
                title: "Guarded Stop requested",
                detail: "The Owner Device confirmed stop for the active Wrapped Session.",
                metadata: ["action": "guarded_stop"]
            )
        )
        try state.append(
            event(
                planningArtifact: context.planningArtifact,
                agentSessionID: context.activeSession.session.id,
                eventType: .sessionLifecycle,
                title: "Wrapped Session stopping",
                detail: "The Mac Agent is attempting graceful interrupt before termination fallback.",
                metadata: ["state": AgentSession.State.stopping.rawValue]
            )
        )

        do {
            let result = try sessionStopper.stopWrappedSession(context.activeSession)
            let foregroundState = try state.completeStop(
                resultEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .structuredActionResult,
                    title: result.method == .gracefulInterrupt
                        ? "Guarded Stop graceful interrupt succeeded"
                        : "Guarded Stop termination fallback succeeded",
                    detail: result.summary,
                    metadata: [
                        "action": "guarded_stop",
                        "method": result.method.rawValue,
                        "result": "success"
                    ]
                ),
                lifecycleEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .sessionLifecycle,
                    title: "Wrapped Session stopped",
                    detail: result.summary,
                    metadata: ["state": AgentSession.State.stopped.rawValue]
                )
            )
            return StopWrappedSessionResponse(foregroundState: foregroundState)
        } catch let error as WrappedSessionStopError {
            try? state.failStop(
                resultEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .structuredActionResult,
                    title: "Guarded Stop failed",
                    detail: error.userMessage,
                    metadata: ["action": "guarded_stop", "result": "failure"]
                ),
                lifecycleEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .sessionLifecycle,
                    title: "Wrapped Session failed to stop",
                    detail: error.userMessage,
                    metadata: ["state": AgentSession.State.failedToStop.rawValue]
                )
            )
            throw error
        } catch {
            let stopError = WrappedSessionStopError.stopFailed(String(describing: error))
            try? state.failStop(
                resultEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .structuredActionResult,
                    title: "Guarded Stop failed",
                    detail: stopError.userMessage,
                    metadata: ["action": "guarded_stop", "result": "failure"]
                ),
                lifecycleEvent: event(
                    planningArtifact: context.planningArtifact,
                    agentSessionID: context.activeSession.session.id,
                    eventType: .sessionLifecycle,
                    title: "Wrapped Session failed to stop",
                    detail: stopError.userMessage,
                    metadata: ["state": AgentSession.State.failedToStop.rawValue]
                )
            )
            throw stopError
        }
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

        let launchResponse = try state.storeLaunchedSession(
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

        guard let transcriptCapturer else {
            return launchResponse
        }

        do {
            if let record = try transcriptCapturer.captureTranscriptChunk(
                for: launchResponse.attachedSession,
                planningArtifact: launchContext.planningArtifact
            ) {
                try state.append(
                    event(
                        planningArtifact: launchContext.planningArtifact,
                        agentSessionID: sessionID,
                        eventType: .sessionLifecycle,
                        title: "Transcript chunk captured",
                        detail: "Appended \(record.byteCount) bytes to the local Transcript File.",
                        metadata: [
                            "transcriptCapture": "success",
                            "transcriptFileID": record.id,
                            "relativePath": record.relativePath,
                            "byteOffsetStart": "\(record.byteOffsetStart)",
                            "byteOffsetEnd": "\(record.byteOffsetEnd)",
                            "byteCount": "\(record.byteCount)"
                        ]
                    )
                )
            }
        } catch let error as TranscriptFileError {
            try? state.append(
                event(
                    planningArtifact: launchContext.planningArtifact,
                    agentSessionID: sessionID,
                    eventType: .sessionLifecycle,
                    title: "Transcript capture failed",
                    detail: error.userMessage,
                    metadata: ["transcriptCapture": "failure"]
                )
            )
        } catch {
            try? state.append(
                event(
                    planningArtifact: launchContext.planningArtifact,
                    agentSessionID: sessionID,
                    eventType: .sessionLifecycle,
                    title: "Transcript capture failed",
                    detail: String(describing: error),
                    metadata: ["transcriptCapture": "failure"]
                )
            )
        }

        return StartWrappedSessionResponse(
            attachedSession: launchResponse.attachedSession,
            foregroundState: try state.foregroundState()
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
            draftComment: StructuredActionState(
                isAvailable: true,
                reason: "Prepare a GitHub Draft Comment",
                requiresConfirmation: true
            ),
            guardedStop: StructuredActionState(isAvailable: false, reason: "No Agent Session")
        ),
        fileReview: FileReviewState(
            status: .unavailable,
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
    private let fileReviewBuilder: any FileReviewBuilding
    private var activeAttachment: PlanningArtifact?
    private var activeSession: AttachedSession?
    private var pendingInput: PendingInputState = .unavailable
    private var pendingApprovalRequest: ApprovalRequestState?
    private var pendingDraftComment: DraftCommentState = .unavailable
    private var decidedApprovalRequestIDs: Set<String> = []
    private var decidedDraftCommentIDs: Set<String> = []

    init(
        configuredRepositoryURL: URL,
        sessionStore: any SessionEventStoring,
        fileReviewBuilder: any FileReviewBuilding
    ) {
        self.configuredRepositoryURL = configuredRepositoryURL
        self.sessionStore = sessionStore
        self.fileReviewBuilder = fileReviewBuilder
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
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
        }
    }

    func store(_ attachment: PlanningArtifact, event: SessionEventLogEntry) throws -> ControlForegroundResponse {
        try lock.withLock {
            try sessionStore.append(event)
            activeAttachment = attachment
            pendingDraftComment = .unavailable
            return try foregroundState(
                for: attachment,
                configuredRepository: configuredRepository,
                activeSession: activeSession,
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
        }
    }

    func prepareLaunch() throws -> WrappedSessionLaunchContext {
        try lock.withLock {
            guard let activeAttachment else {
                throw WrappedSessionLaunchError.noActivePlanningArtifact
            }

            if let activeSession, activeSession.session.state.isActiveWrappedSession {
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
            if let activeSession, activeSession.session.state.isActiveWrappedSession {
                throw WrappedSessionLaunchError.activeSessionAlreadyRunning(activeSession.session.id)
            }

            activeAttachment = planningArtifact
            pendingInput = .unavailable
            pendingApprovalRequest = nil
            pendingDraftComment = .unavailable
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
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
            return StartWrappedSessionResponse(attachedSession: attachedSession, foregroundState: foregroundState)
        }
    }

    func prepareStop(_ request: StopWrappedSessionRequest) throws -> WrappedSessionStopContext {
        try lock.withLock {
            guard request.confirmStop else {
                throw WrappedSessionStopError.confirmationRequired
            }

            guard let activeAttachment, let activeSession, activeSession.session.state.isActiveWrappedSession else {
                throw WrappedSessionStopError.noActiveSession
            }

            let stoppingSession = activeSession.withState(.stopping)
            self.activeSession = stoppingSession
            pendingInput = .unavailable
            pendingApprovalRequest = nil

            return WrappedSessionStopContext(
                planningArtifact: activeAttachment,
                activeSession: stoppingSession
            )
        }
    }

    func completeStop(
        resultEvent: SessionEventLogEntry,
        lifecycleEvent: SessionEventLogEntry
    ) throws -> ControlForegroundResponse {
        try lock.withLock {
            guard let activeAttachment, let activeSession else {
                throw WrappedSessionStopError.noActiveSession
            }

            try sessionStore.append(resultEvent)
            try sessionStore.append(lifecycleEvent)
            pendingInput = .unavailable
            pendingApprovalRequest = nil
            self.activeSession = activeSession.withState(.stopped)

            return try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: self.activeSession,
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
        }
    }

    func failStop(
        resultEvent: SessionEventLogEntry,
        lifecycleEvent: SessionEventLogEntry
    ) throws {
        try lock.withLock {
            guard let activeSession else {
                throw WrappedSessionStopError.noActiveSession
            }

            try sessionStore.append(resultEvent)
            try sessionStore.append(lifecycleEvent)
            pendingInput = .unavailable
            pendingApprovalRequest = nil
            self.activeSession = activeSession.withState(.failedToStop)
        }
    }

    func acceptPendingInputSignal(
        _ signal: PendingInputSignal,
        occurredAt: Date,
        eventID: String
    ) throws -> ControlForegroundResponse {
        try lock.withLock {
            guard let activeAttachment, let activeSession, activeSession.session.state.isActiveWrappedSession else {
                throw PendingInputReplyError.noActiveSession
            }

            let nextPendingInput = nextPendingInputState(from: signal, current: pendingInput, occurredAt: occurredAt)
            pendingInput = nextPendingInput
            self.activeSession = activeSession.withState(sessionState(pendingInput: nextPendingInput, pendingApprovalRequest: pendingApprovalRequest))

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
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
        }
    }

    func acceptApprovalRequestSignal(
        _ signal: ApprovalRequestSignal,
        occurredAt: Date,
        eventID: String
    ) throws -> ControlForegroundResponse {
        try lock.withLock {
            guard let activeAttachment, let activeSession, activeSession.session.state.isActiveWrappedSession else {
                throw ApprovalDecisionError.noActiveSession
            }

            let approvalRequest = ApprovalRequestState(
                requestID: signal.requestID,
                source: signal.source,
                title: signal.title,
                detail: signal.detail,
                requestedAt: occurredAt
            )
            pendingApprovalRequest = approvalRequest
            self.activeSession = activeSession.withState(.waitingForApproval)

            try sessionStore.append(
                SessionEventLogEntry(
                    id: eventID,
                    planningArtifactID: activeAttachment.id,
                    agentSessionID: activeSession.session.id,
                    eventType: .structuredActionAttempt,
                    title: "Approval request detected",
                    detail: signal.title,
                    occurredAt: occurredAt,
                    metadata: [
                        "action": "approval_request",
                        "approvalRequestID": signal.requestID,
                        "approvalRequestSource": signal.source.rawValue
                    ]
                )
            )

            return try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: self.activeSession,
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
        }
    }

    func preparePendingInputReply(_ request: SubmitPendingInputReplyRequest) throws -> PendingInputReplyContext {
        try lock.withLock {
            guard let activeAttachment, let activeSession, activeSession.session.state.isActiveWrappedSession else {
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

    func prepareApprovalDecision(_ request: SubmitApprovalDecisionRequest) throws -> ApprovalDecisionContext {
        try lock.withLock {
            guard let activeAttachment, let activeSession, activeSession.session.state.isActiveWrappedSession else {
                throw ApprovalDecisionError.noActiveSession
            }

            if decidedApprovalRequestIDs.contains(request.requestID) {
                throw ApprovalDecisionError.duplicateDecision
            }

            guard let pendingApprovalRequest else {
                throw ApprovalDecisionError.noPendingApprovalRequest
            }

            guard pendingApprovalRequest.requestID == request.requestID else {
                throw ApprovalDecisionError.staleRequest
            }

            return ApprovalDecisionContext(
                planningArtifact: activeAttachment,
                activeSession: activeSession,
                approvalRequest: pendingApprovalRequest,
                decision: request.decision
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
            self.activeSession = activeSession.withState(sessionState(pendingInput: pendingInput, pendingApprovalRequest: pendingApprovalRequest))

            return try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: self.activeSession,
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
        }
    }

    func completeApprovalDecision(requestID: String, resultEvent: SessionEventLogEntry) throws -> ControlForegroundResponse {
        try lock.withLock {
            guard let activeAttachment, let activeSession else {
                throw ApprovalDecisionError.noActiveSession
            }

            try sessionStore.append(resultEvent)
            decidedApprovalRequestIDs.insert(requestID)
            if pendingApprovalRequest?.requestID == requestID {
                pendingApprovalRequest = nil
            }
            self.activeSession = activeSession.withState(sessionState(pendingInput: pendingInput, pendingApprovalRequest: pendingApprovalRequest))

            return try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: self.activeSession,
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
        }
    }

    func prepareDraftComment(
        draftID: String,
        preparedAt: Date,
        eventID: String
    ) throws -> PrepareDraftCommentResponse {
        try lock.withLock {
            guard let activeAttachment else {
                throw DraftCommentError.noActivePlanningArtifact
            }

            let fileReview = fileReviewBuilder.buildFileReview(
                repositoryURL: configuredRepositoryURL,
                activeSession: activeSession
            )
            let auditEvents = try sessionStore.query(
                SessionEventQuery(planningArtifactID: activeAttachment.id, limit: 20)
            )
            let draft = ObservableDraftCommentBuilder().build(
                draftID: draftID,
                artifact: activeAttachment,
                activeSession: activeSession,
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                fileReview: fileReview,
                auditEvents: auditEvents,
                preparedAt: preparedAt
            )
            pendingDraftComment = draft
            try sessionStore.append(
                SessionEventLogEntry(
                    id: eventID,
                    planningArtifactID: activeAttachment.id,
                    agentSessionID: activeSession?.session.id,
                    eventType: .structuredActionAttempt,
                    title: "Draft Comment prepared",
                    detail: draft.title,
                    occurredAt: preparedAt,
                    metadata: [
                        "action": "draft_comment_prepare",
                        "draftCommentID": draft.id
                    ]
                )
            )

            let foregroundState = try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: activeSession,
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
            return PrepareDraftCommentResponse(draftComment: draft, foregroundState: foregroundState)
        }
    }

    func prepareDraftCommentDecision(_ request: SubmitDraftCommentDecisionRequest) throws -> DraftCommentDecisionContext {
        try lock.withLock {
            guard let activeAttachment else {
                throw DraftCommentError.noActivePlanningArtifact
            }

            if decidedDraftCommentIDs.contains(request.draftID) {
                throw DraftCommentError.duplicateDecision
            }

            guard pendingDraftComment.status == .prepared else {
                throw DraftCommentError.noPreparedDraftComment
            }

            guard pendingDraftComment.id == request.draftID else {
                throw DraftCommentError.staleDraftComment
            }

            let commentBody = (request.approvedBody ?? pendingDraftComment.body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if request.decision == .approve, commentBody.isEmpty {
                throw DraftCommentError.emptyCommentBody
            }

            return DraftCommentDecisionContext(
                planningArtifact: activeAttachment,
                activeSession: activeSession,
                draft: pendingDraftComment,
                decision: request.decision,
                commentBody: commentBody
            )
        }
    }

    func completeDraftCommentRejection(
        draftID: String,
        resultEvent: SessionEventLogEntry
    ) throws -> ControlForegroundResponse {
        try lock.withLock {
            guard let activeAttachment else {
                throw DraftCommentError.noActivePlanningArtifact
            }

            try sessionStore.append(resultEvent)
            decidedDraftCommentIDs.insert(draftID)
            if pendingDraftComment.id == draftID {
                pendingDraftComment.status = .rejected
                pendingDraftComment.requiresApproval = false
            }

            return try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: activeSession,
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
        }
    }

    func completeDraftCommentPost(
        draftID: String,
        postedBody: String,
        resultEvent: SessionEventLogEntry
    ) throws -> ControlForegroundResponse {
        try lock.withLock {
            guard let activeAttachment else {
                throw DraftCommentError.noActivePlanningArtifact
            }

            try sessionStore.append(resultEvent)
            decidedDraftCommentIDs.insert(draftID)
            if pendingDraftComment.id == draftID {
                pendingDraftComment.status = .posted
                pendingDraftComment.body = postedBody
                pendingDraftComment.requiresApproval = false
            }

            return try foregroundState(
                for: activeAttachment,
                configuredRepository: configuredRepository,
                activeSession: activeSession,
                pendingInput: pendingInput,
                pendingApprovalRequest: pendingApprovalRequest,
                draftComment: pendingDraftComment
            )
        }
    }

    func completeDraftCommentFailure(
        draftID: String,
        message: String,
        resultEvent: SessionEventLogEntry
    ) throws {
        try lock.withLock {
            try sessionStore.append(resultEvent)
            if pendingDraftComment.id == draftID {
                pendingDraftComment.status = .failed
                pendingDraftComment.failureMessage = message
                pendingDraftComment.requiresApproval = true
            }
        }
    }

    private func foregroundState(
        for artifact: PlanningArtifact,
        configuredRepository: ConfiguredRepository,
        activeSession: AttachedSession?,
        pendingInput: PendingInputState,
        pendingApprovalRequest: ApprovalRequestState?,
        draftComment: DraftCommentState
    ) throws -> ControlForegroundResponse {
        let attachedSessions = activeSession.map { [$0] } ?? []
        let hasActiveSession = activeSession?.session.state.isActiveWrappedSession == true
        let auditEvents = try sessionStore.query(
            SessionEventQuery(planningArtifactID: artifact.id, limit: 20)
        )

        return ControlForegroundResponse(
            configuredRepository: configuredRepository,
            planningArtifacts: [artifact],
            activePlanningArtifactID: artifact.id,
            attachedSessions: attachedSessions,
            pendingInput: pendingInput,
            pendingApprovalRequest: pendingApprovalRequest,
            draftComment: draftComment,
            structuredActionAvailability: StructuredActionAvailability(
                reply: replyActionState(for: pendingInput),
                approve: approvalActionState(for: pendingApprovalRequest, decision: .approve),
                deny: approvalActionState(for: pendingApprovalRequest, decision: .deny),
                draftComment: StructuredActionState(
                    isAvailable: true,
                    reason: draftComment.status == .prepared
                        ? "Draft Comment is ready for Owner Device approval"
                        : "Prepare a GitHub Draft Comment",
                    requiresConfirmation: true
                ),
                guardedStop: StructuredActionState(
                    isAvailable: hasActiveSession,
                    reason: hasActiveSession ? "Wrapped Session is active" : "No active Wrapped Session",
                    requiresConfirmation: hasActiveSession
                )
            ),
            fileReview: fileReviewBuilder.buildFileReview(
                repositoryURL: configuredRepositoryURL,
                activeSession: activeSession
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

    private func sessionState(
        pendingInput: PendingInputState,
        pendingApprovalRequest: ApprovalRequestState?
    ) -> AgentSession.State {
        if pendingApprovalRequest != nil {
            return .waitingForApproval
        }

        return pendingInput.status == .unavailable ? .running : .waitingForInput
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

    private func approvalActionState(
        for request: ApprovalRequestState?,
        decision: ApprovalRequestDecision
    ) -> StructuredActionState {
        guard let request else {
            return StructuredActionState(isAvailable: false, reason: "No approval request")
        }

        switch decision {
        case .approve:
            return StructuredActionState(
                isAvailable: true,
                reason: "Approve: \(request.title)",
                requiresConfirmation: true
            )
        case .deny:
            return StructuredActionState(
                isAvailable: true,
                reason: "Deny: \(request.title)",
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

private struct WrappedSessionStopContext: Sendable {
    var planningArtifact: PlanningArtifact
    var activeSession: AttachedSession
}

private struct PendingInputReplyContext: Sendable {
    var planningArtifact: PlanningArtifact
    var activeSession: AttachedSession
    var pendingInput: PendingInputState
    var reply: String
}

private struct ApprovalDecisionContext: Sendable {
    var planningArtifact: PlanningArtifact
    var activeSession: AttachedSession
    var approvalRequest: ApprovalRequestState
    var decision: ApprovalRequestDecision
}

private struct DraftCommentDecisionContext: Sendable {
    var planningArtifact: PlanningArtifact
    var activeSession: AttachedSession?
    var draft: DraftCommentState
    var decision: DraftCommentDecision
    var commentBody: String
}

private extension AttachedSession {
    func withState(_ state: AgentSession.State) -> AttachedSession {
        var nextSession = session
        nextSession.state = state
        return AttachedSession(planningArtifactID: planningArtifactID, session: nextSession)
    }
}

private extension AgentSession.State {
    var isActiveWrappedSession: Bool {
        switch self {
        case .running, .waitingForInput, .waitingForApproval, .stopping, .failedToStop:
            return true
        case .idle, .stopped:
            return false
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
