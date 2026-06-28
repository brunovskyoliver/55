import AgentShared
import iPhoneCore
import MacAgentCore
import XCTest

final class WrappedSessionLaunchTests: XCTestCase {
    func testGitWorktreeBaselineCapturerSummarizesCleanBaseline() throws {
        let repositoryURL = URL(fileURLWithPath: "/repo")
        let executor = FakeProcessCommandExecutor(results: [
            "git -C /repo rev-parse --abbrev-ref HEAD": .success("main\n"),
            "git -C /repo rev-parse HEAD": .success("abcdef1234567890\n"),
            "git -C /repo status --porcelain": .success("")
        ])
        let capturer = GitWorktreeBaselineCapturer(
            executor: executor,
            now: { Date(timeIntervalSince1970: 10) }
        )

        let baseline = try capturer.captureBaseline(repositoryURL: repositoryURL)

        XCTAssertFalse(baseline.isDirty)
        XCTAssertEqual(baseline.changedFileCount, 0)
        XCTAssertEqual(baseline.branchName, "main")
        XCTAssertEqual(baseline.headSHA, "abcdef1234567890")
        XCTAssertEqual(baseline.summary, "Clean worktree on main at abcdef123456.")
    }

    func testGitWorktreeBaselineCapturerSurfacesDirtyBaseline() throws {
        let repositoryURL = URL(fileURLWithPath: "/repo")
        let executor = FakeProcessCommandExecutor(results: [
            "git -C /repo rev-parse --abbrev-ref HEAD": .success("feature/session\n"),
            "git -C /repo rev-parse HEAD": .success("1234567890abcdef\n"),
            "git -C /repo status --porcelain": .success(" M Sources/App.swift\n?? Tests/NewTests.swift\n")
        ])
        let capturer = GitWorktreeBaselineCapturer(executor: executor)

        let baseline = try capturer.captureBaseline(repositoryURL: repositoryURL)

        XCTAssertTrue(baseline.isDirty)
        XCTAssertEqual(baseline.changedFileCount, 2)
        XCTAssertEqual(
            baseline.changedFiles,
            [
                WorktreeBaselineFileChange(path: "Sources/App.swift", status: "M"),
                WorktreeBaselineFileChange(path: "Tests/NewTests.swift", status: "??")
            ]
        )
        XCTAssertEqual(baseline.summary, "Dirty worktree: 2 changed files on feature/session at 1234567890ab.")
    }

    func testStartingWrappedSessionCapturesBaselineBeforeTmuxLaunch() throws {
        let events = RecordedLaunchEvents()
        let service = launchableService(
            baseline: .clean,
            tmuxLauncher: FakeTmuxLauncher(events: events),
            events: events
        )
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "5"))

        let response = try service.startWrappedSession()

        XCTAssertEqual(events.values, ["baseline", "tmux"])
        XCTAssertEqual(response.attachedSession.planningArtifactID, "issue-5")
        XCTAssertEqual(response.attachedSession.session.id, "session-5")
        XCTAssertEqual(response.attachedSession.session.state, .running)
        XCTAssertEqual(response.attachedSession.session.tmuxAttachment?.attachCommand, "tmux attach-session -t agent-issue-5")
        XCTAssertEqual(response.attachedSession.session.worktreeBaseline?.summary, "Clean worktree on main at abcdef123456.")
        XCTAssertTrue(response.foregroundState.structuredActionAvailability.guardedStop.isAvailable)
    }

    func testStartingWrappedSessionUsesSeededActivePlanningArtifactWhenNothingElseAttached() throws {
        let service = DemoControlService(
            resolver: StaticPlanningArtifactResolver(),
            configuredRepositoryURL: URL(fileURLWithPath: "/repo"),
            baselineCapturer: FakeBaselineCapturer(baseline: .clean, events: RecordedLaunchEvents()),
            tmuxLauncher: FakeTmuxLauncher(),
            transcriptCapturer: DisabledWrappedSessionTranscriptCapturer(),
            fileReviewBuilder: BaselineEchoFileReviewBuilder(),
            sessionIDGenerator: { "session-2" }
        )

        let response = try service.startWrappedSession()

        XCTAssertEqual(response.attachedSession.planningArtifactID, "issue-2")
        XCTAssertEqual(response.attachedSession.session.tmuxAttachment?.attachCommand, "tmux attach-session -t agent-issue-2")
    }

    func testDirtyBaselineIsAllowedAndSurfacedInSessionState() throws {
        let service = launchableService(baseline: .dirty)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "5"))

        let response = try service.startWrappedSession()

        XCTAssertTrue(response.attachedSession.session.worktreeBaseline?.isDirty == true)
        XCTAssertEqual(response.attachedSession.session.worktreeBaseline?.changedFileCount, 2)
        XCTAssertEqual(response.attachedSession.session.summary, "Running with a dirty Worktree Baseline.")
        XCTAssertEqual(response.foregroundState.fileReview.summary, "Dirty worktree: 2 changed files on main at abcdef123456.")
    }

    func testStartingWrappedSessionRejectsActiveSessionConflict() throws {
        let launcher = FakeTmuxLauncher()
        let service = launchableService(baseline: .clean, tmuxLauncher: launcher)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "5"))
        _ = try service.startWrappedSession()

        XCTAssertThrowsError(try service.startWrappedSession()) { error in
            XCTAssertEqual(error as? WrappedSessionLaunchError, .activeSessionAlreadyRunning("session-5"))
        }
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testTmuxLaunchFailureDoesNotStoreActiveSession() throws {
        let store = SQLiteSessionStore.inMemory()
        let service = launchableService(
            baseline: .clean,
            tmuxLauncher: FakeTmuxLauncher(error: .tmuxLaunchFailed("tmux is unavailable")),
            sessionStore: store
        )
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "5"))

        XCTAssertThrowsError(try service.startWrappedSession()) { error in
            XCTAssertEqual(error as? WrappedSessionLaunchError, .tmuxLaunchFailed("tmux is unavailable"))
        }

        let foregroundState = try service.foregroundState()
        XCTAssertEqual(foregroundState.attachedSessions.count, 0)
        XCTAssertFalse(foregroundState.structuredActionAvailability.guardedStop.isAvailable)
        XCTAssertEqual(
            try store.query(SessionEventQuery(planningArtifactID: "issue-5")).map(\.eventType),
            [.planningArtifactAttached, .structuredActionAttempt, .structuredActionResult]
        )
    }

    func testSuccessfulWrappedSessionStateMapsForIPhone() throws {
        let service = launchableService(baseline: .dirty)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "5"))

        let response = try service.startWrappedSession()
        let state = try PlanningStateMapper().map(response.foregroundState)

        XCTAssertEqual(state.configuredRepositoryPath, "/repo")
        XCTAssertEqual(state.attachedSession?.id, "session-5")
        XCTAssertEqual(state.attachedSession?.stateText, "Running")
        XCTAssertEqual(state.attachedSession?.tmuxAttachCommand, "tmux attach-session -t agent-issue-5")
        XCTAssertEqual(state.attachedSession?.baselineSummary, "Dirty worktree: 2 changed files on main at abcdef123456.")
        XCTAssertEqual(state.attachedSession?.baselineIsDirty, true)
    }

    func testLocalControlAPIResponderStartsWrappedSession() throws {
        let service = launchableService(baseline: .clean)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "5"))
        let responder = LocalControlAPIResponder(provider: service, securityPolicy: .unsecuredDemo)

        let response = responder.response(for: postRequest(path: LocalControlAPIServer.wrappedSessionStartPath, body: Data("{}".utf8)))

        XCTAssertEqual(response.statusCode, 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let launch = try decoder.decode(StartWrappedSessionResponse.self, from: response.body)
        XCTAssertEqual(launch.attachedSession.session.id, "session-5")
        XCTAssertEqual(launch.foregroundState.attachedSessions.first?.session.tmuxAttachment?.sessionName, "agent-issue-5")
    }

    func testWrappedSessionLaunchRecordsAuditTimelineEvents() throws {
        let store = SQLiteSessionStore.inMemory()
        let service = launchableService(baseline: .clean, sessionStore: store)
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "5"))

        let response = try service.startWrappedSession()
        let storedEvents = try store.query(SessionEventQuery(planningArtifactID: "issue-5"))

        XCTAssertEqual(
            storedEvents.map(\.eventType),
            [.planningArtifactAttached, .structuredActionAttempt, .structuredActionResult, .sessionLifecycle]
        )
        XCTAssertEqual(storedEvents.filter { $0.agentSessionID == "session-5" }.count, 3)
        XCTAssertEqual(response.foregroundState.auditTimeline.entries.map(\.title), storedEvents.map(\.title))
    }

    func testGhosttyLauncherReusesRunningGhosttyWhenAppleScriptSucceeds() {
        let executor = FakeProcessCommandExecutor(results: [
            "osascript": .success("")
        ])
        let launcher = GhosttyLauncher(
            executor: executor,
            runningProbe: FakeGhosttyRunningProbe(isRunning: true)
        )

        let warning = launcher.openOrFocus(
            attachCommand: "tmux attach-session -t agent-issue-15",
            sessionName: "agent-issue-15"
        )

        XCTAssertNil(warning)
        XCTAssertEqual(executor.executedCommands.map(\.executable), ["osascript"])
    }

    func testGhosttyLauncherFallsBackToFreshLaunchWhenReuseFails() {
        let executor = FakeProcessCommandExecutor(results: [
            "osascript": .failure(ProcessCommandFailure(
                executable: "osascript",
                arguments: [],
                exitCode: 1,
                stderr: "System Events is not allowed to send keystrokes."
            )),
            "open": .success("")
        ])
        let launcher = GhosttyLauncher(
            executor: executor,
            runningProbe: FakeGhosttyRunningProbe(isRunning: true)
        )

        let warning = launcher.openOrFocus(
            attachCommand: "tmux attach-session -t agent-issue-15",
            sessionName: "agent-issue-15"
        )

        XCTAssertNil(warning)
        XCTAssertEqual(executor.executedCommands.map(\.executable), ["osascript", "open"])
        XCTAssertEqual(
            executor.executedCommands.last?.arguments,
            ["-na", "Ghostty.app", "--args", "-e", "tmux", "attach-session", "-t", "agent-issue-15"]
        )
    }

    func testGhosttyLauncherFreshLaunchesWhenGhosttyIsNotRunning() {
        let executor = FakeProcessCommandExecutor(results: [
            "open": .success("")
        ])
        let launcher = GhosttyLauncher(
            executor: executor,
            runningProbe: FakeGhosttyRunningProbe(isRunning: false)
        )

        let warning = launcher.openOrFocus(
            attachCommand: "tmux attach-session -t agent-issue-15",
            sessionName: "agent-issue-15"
        )

        XCTAssertNil(warning)
        XCTAssertEqual(executor.executedCommands.map(\.executable), ["open"])
    }
}

private func launchableService(
    baseline: FakeBaselineCapturer.Baseline,
    tmuxLauncher: FakeTmuxLauncher = FakeTmuxLauncher(),
    events: RecordedLaunchEvents = RecordedLaunchEvents(),
    sessionStore: any SessionEventStoring = SQLiteSessionStore.inMemory()
) -> DemoControlService {
    DemoControlService(
        resolver: StaticPlanningArtifactResolver(),
        configuredRepositoryURL: URL(fileURLWithPath: "/repo"),
        baselineCapturer: FakeBaselineCapturer(baseline: baseline, events: events),
        tmuxLauncher: tmuxLauncher,
        transcriptCapturer: DisabledWrappedSessionTranscriptCapturer(),
        fileReviewBuilder: BaselineEchoFileReviewBuilder(),
        sessionStore: sessionStore,
        sessionIDGenerator: { "session-5" }
    )
}

private struct StaticPlanningArtifactResolver: PlanningArtifactResolving {
    func resolve(_ request: AttachPlanningArtifactRequest) throws -> PlanningArtifact {
        PlanningArtifact(
            id: "issue-5",
            kind: .issue,
            number: 5,
            title: "Launch a Claude Code Wrapped Session with tmux and Worktree Baseline",
            url: URL(string: "https://github.com/brunovskyoliver/55/issues/5")!,
            state: "open"
        )
    }
}

private struct FakeBaselineCapturer: WorktreeBaselineCapturing {
    enum Baseline {
        case clean
        case dirty
    }

    let baseline: Baseline
    let events: RecordedLaunchEvents

    func captureBaseline(repositoryURL: URL) throws -> WorktreeBaselineSummary {
        events.append("baseline")
        let isDirty = baseline == .dirty
        let changedFileCount = isDirty ? 2 : 0
        let summary = isDirty
            ? "Dirty worktree: 2 changed files on main at abcdef123456."
            : "Clean worktree on main at abcdef123456."

        return WorktreeBaselineSummary(
            repositoryPath: repositoryURL.path,
            branchName: "main",
            headSHA: "abcdef1234567890",
            isDirty: isDirty,
            changedFileCount: changedFileCount,
            summary: summary,
            capturedAt: Date(timeIntervalSince1970: 20)
        )
    }
}

private final class FakeTmuxLauncher: TmuxLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let error: WrappedSessionLaunchError?
    private let events: RecordedLaunchEvents?
    private var count = 0

    init(error: WrappedSessionLaunchError? = nil, events: RecordedLaunchEvents? = nil) {
        self.error = error
        self.events = events
    }

    var launchCount: Int {
        lock.withLock { count }
    }

    func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL
    ) throws -> TmuxAttachmentInfo {
        try lock.withLock {
            count += 1
            events?.append("tmux")

            if let error {
                throw error
            }

            return TmuxAttachmentInfo(
                sessionName: "agent-\(planningArtifact.id)",
                windowName: "claude",
                attachCommand: "tmux attach-session -t agent-\(planningArtifact.id)"
            )
        }
    }
}

private struct BaselineEchoFileReviewBuilder: FileReviewBuilding {
    func buildFileReview(repositoryURL: URL, activeSession: AttachedSession?) -> FileReviewState {
        guard let baseline = activeSession?.session.worktreeBaseline else {
            return FileReviewState(
                status: .unavailable,
                summary: "File Review is unavailable until a Wrapped Session starts.",
                changedFileCount: 0
            )
        }

        return FileReviewState(
            status: baseline.changedFileCount == 0 ? .noChanges : .changesAvailable,
            summary: baseline.summary,
            changedFileCount: baseline.changedFileCount,
            preExistingChangeCount: baseline.changedFileCount,
            agentSessionChangeCount: 0
        )
    }
}

private final class RecordedLaunchEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [String] = []

    var values: [String] {
        lock.withLock { recordedValues }
    }

    func append(_ value: String) {
        lock.withLock {
            recordedValues.append(value)
        }
    }
}

private final class FakeProcessCommandExecutor: ProcessCommandExecuting, @unchecked Sendable {
    enum Result {
        case success(String)
        case failure(ProcessCommandFailure)
    }

    struct ExecutedCommand: Equatable {
        var executable: String
        var arguments: [String]
    }

    private let lock = NSLock()
    private let results: [String: Result]
    private var commands: [ExecutedCommand] = []

    init(results: [String: Result]) {
        self.results = results
    }

    var executedCommands: [ExecutedCommand] {
        lock.withLock { commands }
    }

    func run(executable: String, arguments: [String]) throws -> ProcessCommandResult {
        lock.withLock {
            commands.append(ExecutedCommand(executable: executable, arguments: arguments))
        }
        let key = ([executable] + arguments).joined(separator: " ")
        switch results[key] ?? results[executable] {
        case .success(let text):
            return ProcessCommandResult(stdout: Data(text.utf8))
        case .failure(let error):
            throw error
        case nil:
            throw ProcessCommandFailure(
                executable: executable,
                arguments: arguments,
                exitCode: 1,
                stderr: "unexpected command: \(key)"
            )
        }
    }
}

private struct FakeGhosttyRunningProbe: GhosttyRunningProbing {
    var isRunning: Bool

    func isGhosttyRunning() -> Bool {
        isRunning
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
