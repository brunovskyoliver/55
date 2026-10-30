import XCTest
@testable import MacAgentCore
import AgentShared

// MARK: - State machine unit tests
// These tests exercise the ClaudeCodeAdapter with synthetic hook-event sequences.
// No live Claude Code process is needed.

@MainActor
final class ClaudeCodeAdapterTests: XCTestCase {
    // MARK: - Helpers

    private func makeAdapter() -> ClaudeCodeAdapter {
        let adapter = ClaudeCodeAdapter(executor: NoopProcessCommandExecutor())
        adapter.sessionLaunched(
            wrappedSessionID: "test-session",
            tmuxSessionName: "agent-test",
            tmuxWindowName: "claude",
            hookServerPort: 9999
        )
        return adapter
    }

    private func event(
        _ name: String,
        toolName: String? = nil,
        transcriptPath: String? = nil
    ) -> ClaudeHookEvent {
        let payload = makePayload(
            hookEventName: name,
            toolName: toolName,
            transcriptPath: transcriptPath
        )
        return ClaudeHookEvent(
            wrappedSessionID: "test-session",
            payload: payload,
            rawBody: Data()
        )
    }

    // MARK: - Basic lifecycle

    func testSessionLaunchedSetsLaunchingState() {
        let adapter = ClaudeCodeAdapter(executor: NoopProcessCommandExecutor())
        adapter.sessionLaunched(
            wrappedSessionID: "s1",
            tmuxSessionName: "agent-s1",
            tmuxWindowName: "claude",
            hookServerPort: 9999
        )
        // Wait for main-queue dispatch
        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(adapter.debugState.sessionState, .launching)
    }

    func testSessionStartHookMovesToIdle() {
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))

        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(adapter.debugState.sessionState, .idle)
    }

    func testUserPromptSubmitMovesToWorking() {
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("UserPromptSubmit"))

        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(adapter.debugState.sessionState, .working(activeTool: nil))
    }

    func testPreToolUseAddsActiveTool() {
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("UserPromptSubmit"))
        adapter.ingest(event("PreToolUse", toolName: "Bash"))

        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        let expected = AdapterSessionState.working(activeTool: ActiveTool(name: "Bash", kind: .shell))
        XCTAssertEqual(adapter.debugState.sessionState, expected)
    }

    func testPostToolUseClearsActiveTool() {
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("UserPromptSubmit"))
        adapter.ingest(event("PreToolUse", toolName: "Write"))
        adapter.ingest(event("PostToolUse", toolName: "Write"))

        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(adapter.debugState.sessionState, .working(activeTool: nil))
    }

    func testStopAfterWorkMoveToIdle() {
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("UserPromptSubmit"))
        adapter.ingest(event("Stop"))

        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(adapter.debugState.sessionState, .idle)
    }

    func testSessionEndMovesToEnded() {
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("SessionEnd"))

        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(adapter.debugState.sessionState, .ended(reason: .completed))
    }

    // MARK: - D4: Approval-vs-idle discriminator (event ordering, not message text)

    func testNotificationWithOutstandingToolIsPendingApproval() {
        // PreToolUse received but no PostToolUse → Notification = approval (hook-confirmed)
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("UserPromptSubmit"))
        adapter.ingest(event("PreToolUse", toolName: "Bash"))
        adapter.ingest(event("Notification"))  // tool still outstanding

        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        if case .pendingApproval(let ctx) = adapter.debugState.sessionState {
            XCTAssertEqual(ctx.toolName, "Bash")
        } else {
            XCTFail("Expected pendingApproval, got \(adapter.debugState.sessionState.displayName)")
        }

        // Confidence must be hook-confirmed
        XCTAssertEqual(adapter.debugState.pendingInputDetail?.confidence, .hookConfirmed)
        XCTAssertEqual(adapter.debugState.pendingInputDetail?.kind, .approval)
    }

    func testNotificationWithoutOutstandingToolIsPendingUserInput() {
        // No outstanding PreToolUse → Notification = idle waiting (Uncertain)
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("UserPromptSubmit"))
        adapter.ingest(event("PreToolUse", toolName: "Bash"))
        adapter.ingest(event("PostToolUse", toolName: "Bash"))  // tool cleared
        adapter.ingest(event("Notification"))  // no outstanding tool

        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(adapter.debugState.sessionState, .pendingUserInput)
        XCTAssertEqual(adapter.debugState.pendingInputDetail?.confidence, .uncertain)
        XCTAssertEqual(adapter.debugState.pendingInputDetail?.kind, .userInput)
    }

    func testApprovalFollowedByPostToolUseClearsApproval() {
        // After the user approves (PostToolUse fires), state should return to working.
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("UserPromptSubmit"))
        adapter.ingest(event("PreToolUse", toolName: "Write"))
        adapter.ingest(event("Notification"))  // pendingApproval
        adapter.ingest(event("PostToolUse", toolName: "Write"))  // user approved → tool ran

        let exp = expectation(description: "state")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        // After PostToolUse, back to working with no active tool.
        XCTAssertEqual(adapter.debugState.sessionState, .working(activeTool: nil))
    }

    // MARK: - Transition log

    func testTransitionsAreRecorded() {
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("UserPromptSubmit"))

        let exp = expectation(description: "transitions")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        let transitions = adapter.debugState.stateTransitions
        XCTAssertFalse(transitions.isEmpty)
        XCTAssertTrue(transitions.contains(where: { $0.to == .idle }))
        XCTAssertTrue(transitions.contains(where: { $0.to == .working(activeTool: nil) }))
    }

    // MARK: - Hook event history

    func testHookEventsAreRecorded() {
        let adapter = makeAdapter()
        adapter.ingest(event("SessionStart"))
        adapter.ingest(event("PreToolUse", toolName: "Bash"))

        let exp = expectation(description: "events")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)

        let events = adapter.debugState.recentHookEvents
        XCTAssertTrue(events.contains(where: { $0.eventName == "SessionStart" }))
        XCTAssertTrue(events.contains(where: { $0.eventName == "PreToolUse" && $0.toolName == "Bash" }))
    }
}

// MARK: - ClaudeHookPayload factory for testing
// ClaudeHookPayload uses Decodable synthesis, so we build test instances via JSON.

private func makePayload(
    hookEventName: String,
    toolName: String? = nil,
    transcriptPath: String? = nil,
    sessionId: String = "claude-session-1"
) -> ClaudeHookPayload {
    var dict: [String: Any] = [
        "session_id": sessionId,
        "hook_event_name": hookEventName,
    ]
    if let tp = transcriptPath { dict["transcript_path"] = tp }
    if let tn = toolName { dict["tool_name"] = tn }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(ClaudeHookPayload.self, from: data)
}

// MARK: - Noop executor (no tmux calls during unit tests)

private struct NoopProcessCommandExecutor: ProcessCommandExecuting {
    func run(executable: String, arguments: [String]) throws -> ProcessCommandResult {
        // list-clients returns empty → no tmux client attached
        if executable == "tmux" && arguments.contains("list-clients") {
            return ProcessCommandResult(stdout: Data("".utf8))
        }
        return ProcessCommandResult(stdout: Data())
    }
}
