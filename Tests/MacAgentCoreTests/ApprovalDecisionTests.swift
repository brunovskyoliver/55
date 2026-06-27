import AgentShared
import MacAgentCore
import XCTest

final class ApprovalDecisionTests: XCTestCase {
    func testApprovalRequestApproveIsSentAndRecorded() throws {
        let store = SQLiteSessionStore.inMemory()
        let decisionSender = RecordingApprovalDecisionSender()
        let service = approvalService(sessionStore: store, approvalDecisionSender: decisionSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "8"))
        _ = try service.startWrappedSession()

        let pendingState = try service.acceptApprovalRequestSignal(
            .claudeCodeHook(
                requestID: "approval-1",
                title: "Allow command?",
                detail: "Claude Code wants to run swift test."
            )
        )

        XCTAssertEqual(pendingState.pendingApprovalRequest?.requestID, "approval-1")
        XCTAssertTrue(pendingState.structuredActionAvailability.approve.isAvailable)
        XCTAssertTrue(pendingState.structuredActionAvailability.deny.isAvailable)
        XCTAssertTrue(pendingState.structuredActionAvailability.approve.requiresConfirmation)
        XCTAssertEqual(pendingState.attachedSessions.first?.session.state, .waitingForApproval)

        let response = try service.submitApprovalDecision(
            SubmitApprovalDecisionRequest(requestID: "approval-1", decision: .approve)
        )

        XCTAssertEqual(decisionSender.sentDecisions, [.approve])
        XCTAssertNil(response.foregroundState.pendingApprovalRequest)
        XCTAssertEqual(response.foregroundState.attachedSessions.first?.session.state, .running)
        let eventTitles = try store.query(SessionEventQuery(planningArtifactID: "issue-8")).map(\.title)
        XCTAssertTrue(eventTitles.contains("Approval request detected"))
        XCTAssertTrue(eventTitles.contains("Approval decision delivered"))
    }

    func testApprovalRequestDenyIsSentAndRecorded() throws {
        let store = SQLiteSessionStore.inMemory()
        let decisionSender = RecordingApprovalDecisionSender()
        let service = approvalService(sessionStore: store, approvalDecisionSender: decisionSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "8"))
        _ = try service.startWrappedSession()
        _ = try service.acceptApprovalRequestSignal(
            .claudeCodeHook(requestID: "approval-2", title: "Allow edit?", detail: "Claude Code wants to edit a file.")
        )

        let response = try service.submitApprovalDecision(
            SubmitApprovalDecisionRequest(requestID: "approval-2", decision: .deny)
        )

        XCTAssertEqual(decisionSender.sentDecisions, [.deny])
        XCTAssertNil(response.foregroundState.pendingApprovalRequest)
        let eventTitles = try store.query(SessionEventQuery(planningArtifactID: "issue-8")).map(\.title)
        XCTAssertTrue(eventTitles.contains("Approval request denied"))
        XCTAssertTrue(eventTitles.contains("Denial decision delivered"))
    }

    func testDuplicateApprovalDecisionIsRejected() throws {
        let decisionSender = RecordingApprovalDecisionSender()
        let service = approvalService(approvalDecisionSender: decisionSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "8"))
        _ = try service.startWrappedSession()
        _ = try service.acceptApprovalRequestSignal(
            .claudeCodeHook(requestID: "approval-3", title: "Allow command?", detail: "Run tests.")
        )
        _ = try service.submitApprovalDecision(
            SubmitApprovalDecisionRequest(requestID: "approval-3", decision: .approve)
        )

        XCTAssertThrowsError(
            try service.submitApprovalDecision(
                SubmitApprovalDecisionRequest(requestID: "approval-3", decision: .approve)
            )
        ) { error in
            XCTAssertEqual(error as? ApprovalDecisionError, .duplicateDecision)
        }
        XCTAssertEqual(decisionSender.sentDecisions, [.approve])
    }

    func testStaleApprovalDecisionIsRejected() throws {
        let decisionSender = RecordingApprovalDecisionSender()
        let service = approvalService(approvalDecisionSender: decisionSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "8"))
        _ = try service.startWrappedSession()
        _ = try service.acceptApprovalRequestSignal(
            .claudeCodeHook(requestID: "approval-current", title: "Allow command?", detail: "Run tests.")
        )

        XCTAssertThrowsError(
            try service.submitApprovalDecision(
                SubmitApprovalDecisionRequest(requestID: "approval-old", decision: .deny)
            )
        ) { error in
            XCTAssertEqual(error as? ApprovalDecisionError, .staleRequest)
        }
        XCTAssertEqual(decisionSender.sentDecisions, [])
    }

    func testLocalControlAPIResponderSubmitsApprovalDecision() throws {
        let decisionSender = RecordingApprovalDecisionSender()
        let service = approvalService(approvalDecisionSender: decisionSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "8"))
        _ = try service.startWrappedSession()
        _ = try service.acceptApprovalRequestSignal(
            .claudeCodeHook(requestID: "approval-api", title: "Allow command?", detail: "Run tests.")
        )
        let responder = LocalControlAPIResponder(provider: service, securityPolicy: .unsecuredDemo)
        let encoder = JSONEncoder()
        let body = try encoder.encode(
            SubmitApprovalDecisionRequest(requestID: "approval-api", decision: .approve)
        )

        let response = responder.response(for: postRequest(path: LocalControlAPIServer.approvalDecisionPath, body: body))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(decisionSender.sentDecisions, [.approve])
    }
}

private func approvalService(
    sessionStore: any SessionEventStoring = SQLiteSessionStore.inMemory(),
    approvalDecisionSender: RecordingApprovalDecisionSender
) -> DemoControlService {
    DemoControlService(
        resolver: ApprovalPlanningArtifactResolver(),
        configuredRepositoryURL: URL(fileURLWithPath: "/repo"),
        baselineCapturer: ApprovalBaselineCapturer(),
        tmuxLauncher: ApprovalTmuxLauncher(),
        transcriptCapturer: DisabledWrappedSessionTranscriptCapturer(),
        inputSender: NoopInputSender(),
        approvalDecisionSender: approvalDecisionSender,
        sessionStore: sessionStore,
        sessionIDGenerator: { "session-8" }
    )
}

private struct ApprovalPlanningArtifactResolver: PlanningArtifactResolving {
    func resolve(_ request: AttachPlanningArtifactRequest) throws -> PlanningArtifact {
        PlanningArtifact(
            id: "issue-8",
            kind: .issue,
            number: 8,
            title: "Handle Claude Code approve and deny Structured Actions",
            url: URL(string: "https://github.com/brunovskyoliver/55/issues/8")!,
            state: "open"
        )
    }
}

private struct ApprovalBaselineCapturer: WorktreeBaselineCapturing {
    func captureBaseline(repositoryURL: URL) throws -> WorktreeBaselineSummary {
        WorktreeBaselineSummary(
            repositoryPath: repositoryURL.path,
            branchName: "main",
            headSHA: "abcdef1234567890",
            isDirty: false,
            changedFileCount: 0,
            summary: "Clean worktree on main at abcdef123456.",
            capturedAt: Date(timeIntervalSince1970: 20)
        )
    }
}

private struct ApprovalTmuxLauncher: TmuxLaunching {
    func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL
    ) throws -> TmuxAttachmentInfo {
        TmuxAttachmentInfo(
            sessionName: "agent-issue-8",
            windowName: "claude",
            attachCommand: "tmux attach-session -t agent-issue-8"
        )
    }
}

private struct NoopInputSender: WrappedSessionInputSending {
    func sendReply(_ reply: String, to session: AttachedSession) throws {}
}

private final class RecordingApprovalDecisionSender: ApprovalDecisionSending, @unchecked Sendable {
    private let lock = NSLock()
    private var decisions: [ApprovalRequestDecision] = []

    var sentDecisions: [ApprovalRequestDecision] {
        lock.withLock { decisions }
    }

    func sendApprovalDecision(_ decision: ApprovalRequestDecision, to session: AttachedSession) throws {
        lock.withLock {
            decisions.append(decision)
        }
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
