import AgentShared
import MacAgentCore
import XCTest

final class PendingInputReplyTests: XCTestCase {
    func testHookConfirmedPendingInputReplyIsSentAndRecorded() throws {
        let store = SQLiteSessionStore.inMemory()
        let inputSender = RecordingInputSender()
        let service = pendingInputService(sessionStore: store, inputSender: inputSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "7"))
        _ = try service.startWrappedSession()

        let pendingState = try service.acceptPendingInputSignal(.hookConfirmed(prompt: "Continue?"))

        XCTAssertEqual(pendingState.pendingInput.status, .hookConfirmed)
        XCTAssertTrue(pendingState.structuredActionAvailability.reply.isAvailable)
        XCTAssertFalse(pendingState.structuredActionAvailability.reply.requiresConfirmation)
        XCTAssertEqual(pendingState.attachedSessions.first?.session.state, .waitingForInput)

        let response = try service.submitPendingInputReply(SubmitPendingInputReplyRequest(reply: "yes"))

        XCTAssertEqual(inputSender.sentReplies, ["yes"])
        XCTAssertEqual(response.foregroundState.pendingInput.status, .unavailable)
        XCTAssertEqual(response.foregroundState.attachedSessions.first?.session.state, .running)
        XCTAssertTrue(
            try store.query(SessionEventQuery(planningArtifactID: "issue-7"))
                .contains { $0.title == "Pending Input reply sent" }
        )
    }

    func testHeuristicPendingInputRequiresConfirmationBeforeReply() throws {
        let inputSender = RecordingInputSender()
        let service = pendingInputService(inputSender: inputSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "7"))
        _ = try service.startWrappedSession()

        let pendingState = try service.acceptPendingInputSignal(.tmuxHeuristic(prompt: "tmux prompt"))

        XCTAssertEqual(pendingState.pendingInput.status, .uncertain)
        XCTAssertTrue(pendingState.structuredActionAvailability.reply.isAvailable)
        XCTAssertTrue(pendingState.structuredActionAvailability.reply.requiresConfirmation)
        XCTAssertThrowsError(try service.submitPendingInputReply(SubmitPendingInputReplyRequest(reply: "confirmed"))) { error in
            XCTAssertEqual(error as? PendingInputReplyError, .uncertainInputRequiresConfirmation)
        }

        _ = try service.submitPendingInputReply(
            SubmitPendingInputReplyRequest(reply: "confirmed", confirmUncertainInput: true)
        )

        XCTAssertEqual(inputSender.sentReplies, ["confirmed"])
    }

    func testHeuristicCancellationClearsUncertainPendingInput() throws {
        let inputSender = RecordingInputSender()
        let service = pendingInputService(inputSender: inputSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "7"))
        _ = try service.startWrappedSession()
        _ = try service.acceptPendingInputSignal(.tmuxHeuristic(prompt: "tmux prompt"))

        let foregroundState = try service.acceptPendingInputSignal(.tmuxHeuristicCleared())

        XCTAssertEqual(foregroundState.pendingInput.status, .unavailable)
        XCTAssertFalse(foregroundState.structuredActionAvailability.reply.isAvailable)
        XCTAssertEqual(foregroundState.attachedSessions.first?.session.state, .running)
        XCTAssertThrowsError(
            try service.submitPendingInputReply(
                SubmitPendingInputReplyRequest(reply: "too late", confirmUncertainInput: true)
            )
        ) { error in
            XCTAssertEqual(error as? PendingInputReplyError, .noPendingInput)
        }
        XCTAssertEqual(inputSender.sentReplies, [])
    }

    func testNoPendingInputReplyIsRejected() throws {
        let inputSender = RecordingInputSender()
        let service = pendingInputService(inputSender: inputSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "7"))
        _ = try service.startWrappedSession()

        XCTAssertThrowsError(try service.submitPendingInputReply(SubmitPendingInputReplyRequest(reply: "hello"))) { error in
            XCTAssertEqual(error as? PendingInputReplyError, .noPendingInput)
        }
        XCTAssertEqual(inputSender.sentReplies, [])
    }

    func testFalsePositiveHeuristicClearDoesNotOverrideHookConfirmedPendingInput() throws {
        let inputSender = RecordingInputSender()
        let service = pendingInputService(inputSender: inputSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "7"))
        _ = try service.startWrappedSession()
        _ = try service.acceptPendingInputSignal(.hookConfirmed(prompt: "Hook prompt"))

        let foregroundState = try service.acceptPendingInputSignal(.tmuxHeuristicCleared())

        XCTAssertEqual(foregroundState.pendingInput.status, .hookConfirmed)
        XCTAssertEqual(foregroundState.pendingInput.source, .claudeCodeHook)

        _ = try service.submitPendingInputReply(SubmitPendingInputReplyRequest(reply: "still safe"))

        XCTAssertEqual(inputSender.sentReplies, ["still safe"])
    }

    func testLocalControlAPIResponderSubmitsPendingInputReply() throws {
        let inputSender = RecordingInputSender()
        let service = pendingInputService(inputSender: inputSender)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "7"))
        _ = try service.startWrappedSession()
        _ = try service.acceptPendingInputSignal(.hookConfirmed(prompt: "Continue?"))
        let responder = LocalControlAPIResponder(provider: service, securityPolicy: .unsecuredDemo)
        let encoder = JSONEncoder()
        let body = try encoder.encode(SubmitPendingInputReplyRequest(reply: "api reply"))

        let response = responder.response(for: postRequest(path: LocalControlAPIServer.pendingInputReplyPath, body: body))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(inputSender.sentReplies, ["api reply"])
    }
}

private func pendingInputService(
    sessionStore: any SessionEventStoring = SQLiteSessionStore.inMemory(),
    inputSender: RecordingInputSender
) -> DemoControlService {
    DemoControlService(
        resolver: PendingInputPlanningArtifactResolver(),
        configuredRepositoryURL: URL(fileURLWithPath: "/repo"),
        baselineCapturer: PendingInputBaselineCapturer(),
        tmuxLauncher: PendingInputTmuxLauncher(),
        inputSender: inputSender,
        sessionStore: sessionStore,
        sessionIDGenerator: { "session-7" }
    )
}

private struct PendingInputPlanningArtifactResolver: PlanningArtifactResolving {
    func resolve(_ request: AttachPlanningArtifactRequest) throws -> PlanningArtifact {
        PlanningArtifact(
            id: "issue-7",
            kind: .issue,
            number: 7,
            title: "Detect Pending Input and send guarded replies",
            url: URL(string: "https://github.com/brunovskyoliver/55/issues/7")!,
            state: "open"
        )
    }
}

private struct PendingInputBaselineCapturer: WorktreeBaselineCapturing {
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

private struct PendingInputTmuxLauncher: TmuxLaunching {
    func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL
    ) throws -> TmuxAttachmentInfo {
        TmuxAttachmentInfo(
            sessionName: "agent-issue-7",
            windowName: "claude",
            attachCommand: "tmux attach-session -t agent-issue-7"
        )
    }
}

private final class RecordingInputSender: WrappedSessionInputSending, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String] = []

    var sentReplies: [String] {
        lock.withLock { replies }
    }

    func sendReply(_ reply: String, to session: AttachedSession) throws {
        lock.withLock {
            replies.append(reply)
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
