import AgentShared
import MacAgentCore
import XCTest

final class GuardedStopTests: XCTestCase {
    func testConfirmedStopGracefullyStopsActiveSessionAndRecordsAuditEvents() throws {
        let store = SQLiteSessionStore.inMemory()
        let stopper = RecordingStopper(
            result: WrappedSessionStopResult(
                method: .gracefulInterrupt,
                summary: "Stopped after C-c."
            )
        )
        let service = guardedStopService(sessionStore: store, stopper: stopper)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "11"))
        _ = try service.startWrappedSession()

        let response = try service.stopWrappedSession(StopWrappedSessionRequest(confirmStop: true))

        XCTAssertEqual(stopper.stoppedSessions.first?.session.state, .stopping)
        XCTAssertEqual(response.foregroundState.attachedSessions.first?.session.state, .stopped)
        XCTAssertFalse(response.foregroundState.structuredActionAvailability.guardedStop.isAvailable)
        XCTAssertEqual(
            try store.query(SessionEventQuery(planningArtifactID: "issue-11")).map(\.title),
            [
                "Planning Artifact attached",
                "Start Wrapped Session requested",
                "Start Wrapped Session succeeded",
                "Wrapped Session running",
                "Guarded Stop requested",
                "Wrapped Session stopping",
                "Guarded Stop graceful interrupt succeeded",
                "Wrapped Session stopped"
            ]
        )
    }

    func testUnconfirmedStopIsRejectedWithoutCallingStopper() throws {
        let stopper = RecordingStopper(
            result: WrappedSessionStopResult(method: .gracefulInterrupt, summary: "unused")
        )
        let service = guardedStopService(stopper: stopper)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "11"))
        _ = try service.startWrappedSession()

        XCTAssertThrowsError(try service.stopWrappedSession(StopWrappedSessionRequest(confirmStop: false))) { error in
            XCTAssertEqual(error as? WrappedSessionStopError, .confirmationRequired)
        }

        XCTAssertEqual(stopper.stoppedSessions, [])
        XCTAssertEqual(try service.foregroundState().attachedSessions.first?.session.state, .running)
    }

    func testTerminationFallbackStopsSessionWhenGracefulInterruptDoesNotExit() throws {
        let store = SQLiteSessionStore.inMemory()
        let stopper = RecordingStopper(
            result: WrappedSessionStopResult(
                method: .terminationFallback,
                summary: "Stopped after kill-session."
            )
        )
        let service = guardedStopService(sessionStore: store, stopper: stopper)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "11"))
        _ = try service.startWrappedSession()

        let response = try service.stopWrappedSession(StopWrappedSessionRequest(confirmStop: true))

        XCTAssertEqual(response.foregroundState.attachedSessions.first?.session.state, .stopped)
        XCTAssertTrue(
            try store.query(SessionEventQuery(planningArtifactID: "issue-11"))
                .contains { $0.title == "Guarded Stop termination fallback succeeded" }
        )
    }

    func testStopFailureLeavesSessionFailedToStopAndRecordsFailure() throws {
        let store = SQLiteSessionStore.inMemory()
        let stopper = RecordingStopper(error: .stopFailed("tmux refused to stop"))
        let service = guardedStopService(sessionStore: store, stopper: stopper)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "11"))
        _ = try service.startWrappedSession()

        XCTAssertThrowsError(try service.stopWrappedSession(StopWrappedSessionRequest(confirmStop: true))) { error in
            XCTAssertEqual(error as? WrappedSessionStopError, .stopFailed("tmux refused to stop"))
        }

        let foregroundState = try service.foregroundState()
        XCTAssertEqual(foregroundState.attachedSessions.first?.session.state, .failedToStop)
        XCTAssertTrue(foregroundState.structuredActionAvailability.guardedStop.isAvailable)
        XCTAssertTrue(
            try store.query(SessionEventQuery(planningArtifactID: "issue-11"))
                .contains { $0.title == "Wrapped Session failed to stop" }
        )
    }

    func testNoActiveSessionStopIsRejected() throws {
        let stopper = RecordingStopper(
            result: WrappedSessionStopResult(method: .gracefulInterrupt, summary: "unused")
        )
        let service = guardedStopService(stopper: stopper)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "11"))

        XCTAssertThrowsError(try service.stopWrappedSession(StopWrappedSessionRequest(confirmStop: true))) { error in
            XCTAssertEqual(error as? WrappedSessionStopError, .noActiveSession)
        }
        XCTAssertEqual(stopper.stoppedSessions, [])
    }

    func testLocalControlAPIResponderStopsWrappedSession() throws {
        let stopper = RecordingStopper(
            result: WrappedSessionStopResult(method: .gracefulInterrupt, summary: "Stopped after C-c.")
        )
        let service = guardedStopService(stopper: stopper)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "11"))
        _ = try service.startWrappedSession()
        let responder = LocalControlAPIResponder(provider: service, securityPolicy: .unsecuredDemo)
        let encoder = JSONEncoder()
        let body = try encoder.encode(StopWrappedSessionRequest(confirmStop: true))

        let response = responder.response(for: postRequest(path: LocalControlAPIServer.wrappedSessionStopPath, body: body))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(stopper.stoppedSessions.count, 1)
    }

    func testTmuxStopperUsesGracefulInterruptBeforeTerminationFallback() throws {
        let executor = ScriptedProcessExecutor(steps: [
            .success,
            .success,
            .success,
            .failure("no session")
        ])
        let stopper = TmuxWrappedSessionStopper(
            executor: executor,
            gracefulCheckAttempts: 1,
            gracefulCheckInterval: 0
        )

        let result = try stopper.stopWrappedSession(attachedSession())

        XCTAssertEqual(result.method, .terminationFallback)
        XCTAssertEqual(executor.commands.map(\.arguments), [
            ["send-keys", "-t", "agent-issue-11", "C-c"],
            ["has-session", "-t", "agent-issue-11"],
            ["kill-session", "-t", "agent-issue-11"],
            ["has-session", "-t", "agent-issue-11"]
        ])
    }

    func testTmuxStopperSkipsTerminationFallbackWhenGracefulInterruptStopsSession() throws {
        let executor = ScriptedProcessExecutor(steps: [
            .success,
            .failure("no session")
        ])
        let stopper = TmuxWrappedSessionStopper(
            executor: executor,
            gracefulCheckAttempts: 1,
            gracefulCheckInterval: 0
        )

        let result = try stopper.stopWrappedSession(attachedSession())

        XCTAssertEqual(result.method, .gracefulInterrupt)
        XCTAssertEqual(executor.commands.map(\.arguments), [
            ["send-keys", "-t", "agent-issue-11", "C-c"],
            ["has-session", "-t", "agent-issue-11"]
        ])
    }
}

private func guardedStopService(
    sessionStore: any SessionEventStoring = SQLiteSessionStore.inMemory(),
    stopper: RecordingStopper
) -> DemoControlService {
    DemoControlService(
        resolver: GuardedStopPlanningArtifactResolver(),
        configuredRepositoryURL: URL(fileURLWithPath: "/repo"),
        baselineCapturer: GuardedStopBaselineCapturer(),
        tmuxLauncher: GuardedStopTmuxLauncher(),
        transcriptCapturer: DisabledWrappedSessionTranscriptCapturer(),
        sessionStopper: stopper,
        sessionStore: sessionStore,
        sessionIDGenerator: { "session-11" }
    )
}

private struct GuardedStopPlanningArtifactResolver: PlanningArtifactResolving {
    func resolve(_ request: AttachPlanningArtifactRequest) throws -> PlanningArtifact {
        PlanningArtifact(
            id: "issue-11",
            kind: .issue,
            number: 11,
            title: "Implement Guarded Stop for Wrapped Sessions",
            url: URL(string: "https://github.com/brunovskyoliver/55/issues/11")!,
            state: "open"
        )
    }
}

private struct GuardedStopBaselineCapturer: WorktreeBaselineCapturing {
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

private struct GuardedStopTmuxLauncher: TmuxLaunching {
    func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL
    ) throws -> TmuxAttachmentInfo {
        TmuxAttachmentInfo(
            sessionName: "agent-issue-11",
            windowName: "claude",
            attachCommand: "tmux attach-session -t agent-issue-11"
        )
    }
}

private final class RecordingStopper: WrappedSessionStopping, @unchecked Sendable {
    private let lock = NSLock()
    private let result: WrappedSessionStopResult?
    private let error: WrappedSessionStopError?
    private var sessions: [AttachedSession] = []

    init(result: WrappedSessionStopResult) {
        self.result = result
        self.error = nil
    }

    init(error: WrappedSessionStopError) {
        self.result = nil
        self.error = error
    }

    var stoppedSessions: [AttachedSession] {
        lock.withLock { sessions }
    }

    func stopWrappedSession(_ session: AttachedSession) throws -> WrappedSessionStopResult {
        try lock.withLock {
            sessions.append(session)
            if let error {
                throw error
            }
            return result!
        }
    }
}

private final class ScriptedProcessExecutor: ProcessCommandExecuting, @unchecked Sendable {
    struct Command: Equatable {
        var executable: String
        var arguments: [String]
    }

    enum Step {
        case success
        case failure(String)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var recordedCommands: [Command] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var commands: [Command] {
        lock.withLock { recordedCommands }
    }

    func run(executable: String, arguments: [String]) throws -> ProcessCommandResult {
        try lock.withLock {
            recordedCommands.append(Command(executable: executable, arguments: arguments))
            let step = steps.isEmpty ? Step.success : steps.removeFirst()
            switch step {
            case .success:
                return ProcessCommandResult(stdout: Data())
            case .failure(let stderr):
                throw ProcessCommandFailure(
                    executable: executable,
                    arguments: arguments,
                    exitCode: 1,
                    stderr: stderr
                )
            }
        }
    }
}

private func attachedSession() -> AttachedSession {
    AttachedSession(
        planningArtifactID: "issue-11",
        session: AgentSession(
            id: "session-11",
            displayName: "Claude Code Wrapped Session",
            state: .running,
            summary: "Running.",
            tmuxAttachment: TmuxAttachmentInfo(
                sessionName: "agent-issue-11",
                windowName: "claude",
                attachCommand: "tmux attach-session -t agent-issue-11"
            )
        )
    )
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
