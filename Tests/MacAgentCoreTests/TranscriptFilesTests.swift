import AgentShared
import MacAgentCore
import XCTest

final class TranscriptFilesTests: XCTestCase {
    func testTranscriptFileAppendRecordsOffsetsAndMetadata() throws {
        let databaseURL = try temporaryDatabaseURL()
        let rootDirectory = try temporaryTranscriptDirectory()
        let metadataStore = SQLiteSessionStore(databaseURL: databaseURL)
        let transcriptStore = LocalTranscriptFileStore(
            rootDirectory: rootDirectory,
            metadataStore: metadataStore,
            recordIDGenerator: IncrementingIDGenerator(prefix: "transcript").next
        )

        let first = try transcriptStore.append(
            TranscriptAppendRequest(
                planningArtifactID: "issue-12",
                agentSessionID: "session-12",
                chunk: Data("first".utf8),
                capturedAt: Date(timeIntervalSince1970: 10)
            )
        )
        let second = try transcriptStore.append(
            TranscriptAppendRequest(
                planningArtifactID: "issue-12",
                agentSessionID: "session-12",
                chunk: Data("-second".utf8),
                capturedAt: Date(timeIntervalSince1970: 20)
            )
        )

        XCTAssertEqual(first.byteOffsetStart, 0)
        XCTAssertEqual(first.byteOffsetEnd, 5)
        XCTAssertEqual(second.byteOffsetStart, 5)
        XCTAssertEqual(second.byteOffsetEnd, 12)
        XCTAssertEqual(first.relativePath, second.relativePath)
        XCTAssertEqual(
            try String(contentsOf: rootDirectory.appending(path: first.relativePath), encoding: .utf8),
            "first-second"
        )

        let records = try metadataStore.queryTranscriptMetadata(
            TranscriptFileQuery(planningArtifactID: "issue-12", agentSessionID: "session-12")
        )
        XCTAssertEqual(records.map(\.id), ["transcript-1", "transcript-2"])
        XCTAssertEqual(records.map(\.byteOffsetStart), [0, 5])
        XCTAssertEqual(records.map(\.byteOffsetEnd), [5, 12])
    }

    func testTranscriptFileAppendContinuesOffsetsAfterStoreRestart() throws {
        let databaseURL = try temporaryDatabaseURL()
        let rootDirectory = try temporaryTranscriptDirectory()

        let firstMetadataStore = SQLiteSessionStore(databaseURL: databaseURL)
        let firstTranscriptStore = LocalTranscriptFileStore(
            rootDirectory: rootDirectory,
            metadataStore: firstMetadataStore,
            recordIDGenerator: { "first" }
        )
        let first = try firstTranscriptStore.append(
            TranscriptAppendRequest(
                planningArtifactID: "issue-12",
                agentSessionID: "session-12",
                chunk: Data("hello".utf8),
                capturedAt: Date(timeIntervalSince1970: 10)
            )
        )

        let restartedMetadataStore = SQLiteSessionStore(databaseURL: databaseURL)
        let restartedTranscriptStore = LocalTranscriptFileStore(
            rootDirectory: rootDirectory,
            metadataStore: restartedMetadataStore,
            recordIDGenerator: { "second" }
        )
        let second = try restartedTranscriptStore.append(
            TranscriptAppendRequest(
                planningArtifactID: "issue-12",
                agentSessionID: "session-12",
                chunk: Data(" again".utf8),
                capturedAt: Date(timeIntervalSince1970: 20)
            )
        )

        XCTAssertEqual(first.byteOffsetStart, 0)
        XCTAssertEqual(second.byteOffsetStart, 5)
        XCTAssertEqual(second.byteOffsetEnd, 11)
        XCTAssertEqual(
            try restartedMetadataStore.queryTranscriptMetadata(
                TranscriptFileQuery(planningArtifactID: "issue-12", agentSessionID: "session-12")
            ).map(\.id),
            ["first", "second"]
        )
    }

    func testTmuxTranscriptCapturerAppendsCapturedPaneOutput() throws {
        let databaseURL = try temporaryDatabaseURL()
        let rootDirectory = try temporaryTranscriptDirectory()
        let metadataStore = SQLiteSessionStore(databaseURL: databaseURL)
        let transcriptStore = LocalTranscriptFileStore(
            rootDirectory: rootDirectory,
            metadataStore: metadataStore,
            recordIDGenerator: { "capture-1" }
        )
        let executor = FakeTranscriptProcessExecutor(results: [
            "tmux capture-pane -p -S - -t agent-issue-12": .success("raw transcript\n")
        ])
        let capturer = TmuxWrappedSessionTranscriptCapturer(
            executor: executor,
            transcriptStore: transcriptStore,
            now: { Date(timeIntervalSince1970: 30) }
        )

        let record = try XCTUnwrap(
            capturer.captureTranscriptChunk(
                for: attachedSession(),
                planningArtifact: planningArtifact()
            )
        )

        XCTAssertEqual(record.byteCount, 15)
        XCTAssertEqual(
            try String(contentsOf: rootDirectory.appending(path: record.relativePath), encoding: .utf8),
            "raw transcript\n"
        )
    }

    func testTranscriptCaptureFailureIsSurfacedWithoutDroppingSessionEvents() throws {
        let metadataStore = SQLiteSessionStore.inMemory()
        let service = transcriptService(
            sessionStore: metadataStore,
            transcriptCapturer: FailingTranscriptCapturer(error: .captureFailed("tmux capture failed"))
        )
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "12"))

        let response = try service.startWrappedSession()

        XCTAssertEqual(response.attachedSession.session.state, .running)
        let events = try metadataStore.query(SessionEventQuery(planningArtifactID: "issue-12"))
        XCTAssertTrue(events.map(\.title).contains("Start Wrapped Session succeeded"))
        XCTAssertTrue(events.map(\.title).contains("Wrapped Session running"))
        XCTAssertTrue(events.map(\.title).contains("Transcript capture failed"))
    }

    func testControlAPIStartResponseDoesNotSyncRawTranscriptBytes() throws {
        let databaseURL = try temporaryDatabaseURL()
        let rootDirectory = try temporaryTranscriptDirectory()
        let metadataStore = SQLiteSessionStore(databaseURL: databaseURL)
        let transcriptStore = LocalTranscriptFileStore(
            rootDirectory: rootDirectory,
            metadataStore: metadataStore,
            recordIDGenerator: { "transcript-raw" }
        )
        let service = transcriptService(
            sessionStore: metadataStore,
            transcriptCapturer: AppendingTranscriptCapturer(
                transcriptStore: transcriptStore,
                chunk: "SECRET RAW TRANSCRIPT"
            )
        )
        _ = try service.attachPlanningArtifact(AttachPlanningArtifactRequest(kind: .issue, reference: "12"))
        let responder = LocalControlAPIResponder(provider: service, securityPolicy: .unsecuredDemo)

        let response = responder.response(
            for: postRequest(path: LocalControlAPIServer.wrappedSessionStartPath, body: Data("{}".utf8))
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("SECRET RAW TRANSCRIPT"))
        XCTAssertEqual(
            try metadataStore.queryTranscriptMetadata(
                TranscriptFileQuery(planningArtifactID: "issue-12", agentSessionID: "session-12")
            ).first?.byteCount,
            21
        )
    }
}

private func transcriptService(
    sessionStore: any SessionEventStoring,
    transcriptCapturer: any WrappedSessionTranscriptCapturing
) -> DemoControlService {
    DemoControlService(
        resolver: TranscriptPlanningArtifactResolver(),
        configuredRepositoryURL: URL(fileURLWithPath: "/repo"),
        baselineCapturer: TranscriptBaselineCapturer(),
        tmuxLauncher: TranscriptTmuxLauncher(),
        transcriptCapturer: transcriptCapturer,
        fileReviewBuilder: TranscriptFileReviewBuilder(),
        sessionStore: sessionStore,
        sessionIDGenerator: { "session-12" }
    )
}

private func planningArtifact() -> PlanningArtifact {
    PlanningArtifact(
        id: "issue-12",
        kind: .issue,
        number: 12,
        title: "Retain Raw Transcript chunks as Transcript Files",
        url: URL(string: "https://github.com/brunovskyoliver/55/issues/12")!,
        state: "open"
    )
}

private func attachedSession() -> AttachedSession {
    AttachedSession(
        planningArtifactID: "issue-12",
        session: AgentSession(
            id: "session-12",
            displayName: "Claude Code Wrapped Session",
            state: .running,
            summary: "Running",
            tmuxAttachment: TmuxAttachmentInfo(
                sessionName: "agent-issue-12",
                windowName: "claude",
                attachCommand: "tmux attach-session -t agent-issue-12"
            )
        )
    )
}

private struct TranscriptPlanningArtifactResolver: PlanningArtifactResolving {
    func resolve(_ request: AttachPlanningArtifactRequest) throws -> PlanningArtifact {
        planningArtifact()
    }
}

private struct TranscriptBaselineCapturer: WorktreeBaselineCapturing {
    func captureBaseline(repositoryURL: URL) throws -> WorktreeBaselineSummary {
        WorktreeBaselineSummary(
            repositoryPath: repositoryURL.path,
            branchName: "main",
            headSHA: "abcdef1234567890",
            isDirty: false,
            changedFileCount: 0,
            summary: "Clean worktree on main at abcdef123456.",
            capturedAt: Date(timeIntervalSince1970: 10)
        )
    }
}

private struct TranscriptTmuxLauncher: TmuxLaunching {
    func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL,
        hookServerPort: UInt16
    ) throws -> TmuxLaunchResult {
        TmuxLaunchResult(attachment: TmuxAttachmentInfo(
            sessionName: "agent-issue-12",
            windowName: "claude",
            attachCommand: "tmux attach-session -t agent-issue-12"
        ))
    }
}

private struct TranscriptFileReviewBuilder: FileReviewBuilding {
    func buildFileReview(repositoryURL: URL, activeSession: AttachedSession?) -> FileReviewState {
        FileReviewState(
            status: .noChanges,
            summary: "No changes.",
            changedFileCount: 0
        )
    }
}

private struct AppendingTranscriptCapturer: WrappedSessionTranscriptCapturing {
    let transcriptStore: any TranscriptFileRecording
    let chunk: String

    func captureTranscriptChunk(
        for session: AttachedSession,
        planningArtifact: PlanningArtifact
    ) throws -> TranscriptFileRecord? {
        try transcriptStore.append(
            TranscriptAppendRequest(
                planningArtifactID: planningArtifact.id,
                agentSessionID: session.session.id,
                chunk: Data(chunk.utf8),
                capturedAt: Date(timeIntervalSince1970: 40)
            )
        )
    }
}

private struct FailingTranscriptCapturer: WrappedSessionTranscriptCapturing {
    let error: TranscriptFileError

    func captureTranscriptChunk(
        for session: AttachedSession,
        planningArtifact: PlanningArtifact
    ) throws -> TranscriptFileRecord? {
        throw error
    }
}

private final class IncrementingIDGenerator: @unchecked Sendable {
    private let prefix: String
    private let lock = NSLock()
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

private final class FakeTranscriptProcessExecutor: ProcessCommandExecuting, @unchecked Sendable {
    enum Result {
        case success(String)
        case failure(ProcessCommandFailure)
    }

    private let results: [String: Result]

    init(results: [String: Result]) {
        self.results = results
    }

    func run(executable: String, arguments: [String]) throws -> ProcessCommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        switch results[key] {
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

private func temporaryDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "AgentSessionControlTranscriptTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "session-store.sqlite")
}

private func temporaryTranscriptDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "AgentSessionControlTranscriptFiles-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
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
