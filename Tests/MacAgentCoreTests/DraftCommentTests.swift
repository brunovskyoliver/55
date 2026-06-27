import AgentShared
import MacAgentCore
import XCTest

final class DraftCommentTests: XCTestCase {
    func testPrepareDraftCommentBuildsObservablePreview() throws {
        let store = SQLiteSessionStore.inMemory()
        let service = draftService(sessionStore: store)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "10"))
        _ = try service.startWrappedSession()
        _ = try service.acceptApprovalRequestSignal(
            .claudeCodeHook(
                requestID: "approval-10",
                title: "Allow command?",
                detail: "Claude Code wants to run swift test."
            )
        )

        let response = try service.prepareDraftComment(PrepareDraftCommentRequest())

        XCTAssertEqual(response.draftComment.id, "draft-10")
        XCTAssertEqual(response.draftComment.status, .prepared)
        XCTAssertTrue(response.draftComment.requiresApproval)
        XCTAssertTrue(response.draftComment.body.contains("## Observable Summary"))
        XCTAssertTrue(response.draftComment.body.contains("Approval request detected"))
        XCTAssertTrue(response.draftComment.body.contains("Pending approval: Allow command?"))
        XCTAssertTrue(response.draftComment.body.contains("Sources/App.swift"))
        XCTAssertEqual(response.foregroundState.draftComment.id, "draft-10")
        XCTAssertTrue(response.foregroundState.structuredActionAvailability.draftComment.requiresConfirmation)
        let events = try store.query(SessionEventQuery(planningArtifactID: "issue-10"))
        XCTAssertTrue(events.map(\.title).contains("Draft Comment prepared"))
    }

    func testApprovedDraftCommentPostsThroughGitHubAndRecordsTimeline() throws {
        let store = SQLiteSessionStore.inMemory()
        let poster = RecordingGitHubCommentPoster()
        let service = draftService(sessionStore: store, commentPoster: poster)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "10"))
        _ = try service.startWrappedSession()
        _ = try service.prepareDraftComment(PrepareDraftCommentRequest())

        let response = try service.submitDraftCommentDecision(
            SubmitDraftCommentDecisionRequest(
                draftID: "draft-10",
                decision: .approve,
                approvedBody: "Edited approved body"
            )
        )

        XCTAssertEqual(poster.postedBodies, ["Edited approved body"])
        XCTAssertEqual(poster.postedArtifacts.map(\.id), ["issue-10"])
        XCTAssertEqual(response.foregroundState.draftComment.status, .posted)
        XCTAssertFalse(response.foregroundState.draftComment.requiresApproval)
        XCTAssertEqual(response.foregroundState.draftComment.body, "Edited approved body")
        let events = try store.query(SessionEventQuery(planningArtifactID: "issue-10"))
        XCTAssertTrue(events.contains { $0.eventType == .githubAction && $0.title == "GitHub comment posted" })
        XCTAssertTrue(response.foregroundState.auditTimeline.entries.map(\.title).contains("GitHub comment posted"))
    }

    func testRejectedDraftCommentDoesNotPostToGitHub() throws {
        let poster = RecordingGitHubCommentPoster()
        let service = draftService(commentPoster: poster)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "10"))
        _ = try service.startWrappedSession()
        _ = try service.prepareDraftComment(PrepareDraftCommentRequest())

        let response = try service.submitDraftCommentDecision(
            SubmitDraftCommentDecisionRequest(draftID: "draft-10", decision: .reject)
        )

        XCTAssertEqual(poster.postedBodies, [])
        XCTAssertEqual(response.foregroundState.draftComment.status, .rejected)
        XCTAssertFalse(response.foregroundState.draftComment.requiresApproval)
        XCTAssertTrue(response.foregroundState.auditTimeline.entries.map(\.title).contains("Draft Comment rejected"))
    }

    func testGitHubPostFailureKeepsDraftLocalAndRecordsFailure() throws {
        let store = SQLiteSessionStore.inMemory()
        let poster = RecordingGitHubCommentPoster(error: DraftCommentError.githubPostFailed("gh auth failed"))
        let service = draftService(sessionStore: store, commentPoster: poster)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "10"))
        _ = try service.startWrappedSession()
        _ = try service.prepareDraftComment(PrepareDraftCommentRequest())

        XCTAssertThrowsError(
            try service.submitDraftCommentDecision(
                SubmitDraftCommentDecisionRequest(draftID: "draft-10", decision: .approve)
            )
        ) { error in
            XCTAssertEqual(error as? DraftCommentError, .githubPostFailed("gh auth failed"))
        }

        let foregroundState = try service.foregroundState()
        XCTAssertEqual(foregroundState.draftComment.status, .failed)
        XCTAssertEqual(foregroundState.draftComment.failureMessage, "gh auth failed")
        XCTAssertEqual(poster.postedBodies.count, 1)
        let events = try store.query(SessionEventQuery(planningArtifactID: "issue-10"))
        XCTAssertTrue(events.contains { $0.eventType == .githubAction && $0.title == "GitHub comment post failed" })
    }

    func testLocalControlAPIPreparesAndApprovesDraftComment() throws {
        let poster = RecordingGitHubCommentPoster()
        let service = draftService(commentPoster: poster)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "10"))
        _ = try service.startWrappedSession()
        let responder = LocalControlAPIResponder(provider: service, securityPolicy: .unsecuredDemo)

        let prepareResponse = responder.response(
            for: postRequest(path: LocalControlAPIServer.draftCommentPreparePath, body: Data("{}".utf8))
        )
        XCTAssertEqual(prepareResponse.statusCode, 200)

        let encoder = JSONEncoder()
        let decisionBody = try encoder.encode(
            SubmitDraftCommentDecisionRequest(draftID: "draft-10", decision: .approve)
        )

        let decisionResponse = responder.response(
            for: postRequest(path: LocalControlAPIServer.draftCommentDecisionPath, body: decisionBody)
        )

        XCTAssertEqual(decisionResponse.statusCode, 200)
        XCTAssertEqual(poster.postedBodies.count, 1)
    }
}

private func draftService(
    sessionStore: any SessionEventStoring = SQLiteSessionStore.inMemory(),
    commentPoster: RecordingGitHubCommentPoster = RecordingGitHubCommentPoster()
) -> DemoControlService {
    let eventCounter = DraftIDCounter(prefix: "event")
    return DemoControlService(
        resolver: DraftPlanningArtifactResolver(),
        configuredRepositoryURL: URL(fileURLWithPath: "/repo"),
        baselineCapturer: DraftBaselineCapturer(),
        tmuxLauncher: DraftTmuxLauncher(),
        inputSender: DraftNoopInputSender(),
        approvalDecisionSender: DraftNoopApprovalDecisionSender(),
        commentPoster: commentPoster,
        fileReviewBuilder: DraftFileReviewBuilder(),
        sessionStore: sessionStore,
        sessionIDGenerator: { "session-10" },
        draftIDGenerator: { "draft-10" },
        eventIDGenerator: { eventCounter.next() },
        now: { Date(timeIntervalSince1970: 100) }
    )
}

private final class DraftIDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var value = 0

    init(prefix: String) {
        self.prefix = prefix
    }

    func next() -> String {
        lock.withLock {
            value += 1
            return "\(prefix)-\(value)"
        }
    }
}

private struct DraftPlanningArtifactResolver: PlanningArtifactResolving {
    func resolve(_ request: AttachPlanningArtifactRequest) throws -> PlanningArtifact {
        PlanningArtifact(
            id: "issue-10",
            kind: .issue,
            number: 10,
            title: "Prepare and approve Draft Comments to GitHub",
            url: URL(string: "https://github.com/brunovskyoliver/55/issues/10")!,
            state: "open"
        )
    }
}

private struct DraftBaselineCapturer: WorktreeBaselineCapturing {
    func captureBaseline(repositoryURL: URL) throws -> WorktreeBaselineSummary {
        WorktreeBaselineSummary(
            repositoryPath: repositoryURL.path,
            branchName: "main",
            headSHA: "abcdef1234567890",
            isDirty: false,
            changedFileCount: 0,
            summary: "Clean worktree on main at abcdef123456.",
            capturedAt: Date(timeIntervalSince1970: 90)
        )
    }
}

private struct DraftTmuxLauncher: TmuxLaunching {
    func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL
    ) throws -> TmuxAttachmentInfo {
        TmuxAttachmentInfo(
            sessionName: "agent-issue-10",
            windowName: "claude",
            attachCommand: "tmux attach-session -t agent-issue-10"
        )
    }
}

private struct DraftNoopInputSender: WrappedSessionInputSending {
    func sendReply(_ reply: String, to session: AttachedSession) throws {}
}

private struct DraftNoopApprovalDecisionSender: ApprovalDecisionSending {
    func sendApprovalDecision(_ decision: ApprovalRequestDecision, to session: AttachedSession) throws {}
}

private struct DraftFileReviewBuilder: FileReviewBuilding {
    func buildFileReview(repositoryURL: URL, activeSession: AttachedSession?) -> FileReviewState {
        FileReviewState(
            status: .changesAvailable,
            summary: "1 changed file: 0 pre-existing, 1 Agent Session.",
            changedFileCount: 1,
            preExistingChangeCount: 0,
            agentSessionChangeCount: 1,
            files: [
                FileReviewFile(
                    path: "Sources/App.swift",
                    ownership: .agentSession,
                    changeKind: .modified,
                    additions: 12,
                    deletions: 2,
                    summary: "Modified, +12/-2.",
                    riskSignals: ["Large change"]
                )
            ]
        )
    }
}

private final class RecordingGitHubCommentPoster: GitHubCommentPosting, @unchecked Sendable {
    private let lock = NSLock()
    private let error: DraftCommentError?
    private var bodies: [String] = []
    private var artifacts: [PlanningArtifact] = []

    init(error: DraftCommentError? = nil) {
        self.error = error
    }

    var postedBodies: [String] {
        lock.withLock { bodies }
    }

    var postedArtifacts: [PlanningArtifact] {
        lock.withLock { artifacts }
    }

    func postGeneralComment(_ body: String, to artifact: PlanningArtifact) throws -> GitHubCommentPostResult {
        lock.withLock {
            bodies.append(body)
            artifacts.append(artifact)
        }
        if let error {
            throw error
        }
        return GitHubCommentPostResult(
            url: URL(string: "https://github.com/brunovskyoliver/55/issues/10#issuecomment-1")!,
            summary: "https://github.com/brunovskyoliver/55/issues/10#issuecomment-1"
        )
    }
}

private func postRequest(path: String, body: Data) -> String {
    """
    POST \(path) HTTP/1.1\r
    Host: 127.0.0.1\r
    Content-Type: application/json\r
    Content-Length: \(body.count)\r
    \r
    \(String(decoding: body, as: UTF8.self))
    """
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
