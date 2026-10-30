import MacAgentCore
import XCTest

/// Tests for the Claude session discovery helpers introduced/fixed in 2026-07.
final class SessionDiscoveryTests: XCTestCase {

    // MARK: - isClaudeCodeArgv

    func testNativeBinaryArgvIsRecognised() {
        // Claude Code 2.x ships as a native binary — no "node" in argv.
        let nativeArgv = "/opt/homebrew/Caskroom/claude-code@latest/2.1.195/claude --bg-spare /tmp/cc.sock"
        XCTAssertTrue(isClaudeCodeArgv(nativeArgv))
    }

    func testBareCommandNameIsRecognised() {
        // Some ps output formats show just the bare command name.
        XCTAssertTrue(isClaudeCodeArgv("claude"))
        XCTAssertTrue(isClaudeCodeArgv("claude\n"))
        XCTAssertTrue(isClaudeCodeArgv("claude "))
    }

    func testNodeWrappedArgvNoLongerRejected() {
        // Old node-wrapped invocations (pre-2.x) should still match because
        // the path token ends in "/claude".
        let nodeWrapped = "/usr/local/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js claude"
        // First token is "/usr/local/bin/node" — doesn't end in /claude → false.
        XCTAssertFalse(isClaudeCodeArgv(nodeWrapped))
    }

    func testClaudeAppHelperIsNotRecognised() {
        // The Claude.app Electron helper process contains "Claude" but not the bare `/claude` basename.
        let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=utility"
        XCTAssertFalse(isClaudeCodeArgv(helper))
    }

    func testClaudeRendererHelperIsNotRecognised() {
        let renderer = "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer"
        XCTAssertFalse(isClaudeCodeArgv(renderer))
    }

    func testUnrelatedProcessIsNotRecognised() {
        XCTAssertFalse(isClaudeCodeArgv("zsh"))
        XCTAssertFalse(isClaudeCodeArgv("/usr/bin/python3 script.py"))
        XCTAssertFalse(isClaudeCodeArgv(""))
    }

    // MARK: - AllClaudeSessionEnumerator

    // Key used by enumerateTmuxSessions for its list-panes call.
    private static let listPanesKey =
        "tmux list-panes -a -F #{session_name}\t#{window_name}\t#{pane_pid}\t#{pane_tty}\t#{pane_current_path}\t#{pane_activity}\t#{pane_id}"

    /// Regression test for the daemon-detachment bug: Claude Code's `--bg-pty-host`
    /// architecture makes the real claude process take over the pane's PTY directly,
    /// WITHOUT remaining a child of pane_pid — so pgrep -P tree-walking finds nothing,
    /// even though `ps -t <tty>` (matching by terminal) finds it immediately.
    func testEnumeratorFindsDaemonDetachedClaudeViaTTY() {
        let panePid = 28734
        let paneTTY = "/dev/ttys003"
        let claudeArgv = "claude --allow-dangerously-skip-permissions"

        let executor = FakeProcessCommandExecutor(results: [
            Self.listPanesKey: .success("mysession\tmywindow\t\(panePid)\t\(paneTTY)\t/Users/oliver/code\t1751000000\t%1\n"),
            // ps -t ttys003 lists everything on that terminal, including the
            // daemon-detached claude process — regardless of its real parent pid.
            "ps -t ttys003 -o pid=,args=": .success("\(panePid) -zsh\n54156 \(claudeArgv)\n"),
            "tmux show-environment -t mysession AGENT_WRAPPED_SESSION_ID": .failure(
                ProcessCommandFailure(executable: "tmux", arguments: [], exitCode: 1, stderr: "unknown variable")
            )
        ])

        let enumerator = AllClaudeSessionEnumerator(
            executor: executor,
            now: { Date(timeIntervalSince1970: 1_751_000_000) }
        )
        let sessions = enumerator.enumerateAll()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].tmuxSessionName, "mysession")
        XCTAssertEqual(sessions[0].kind, .externalTmux)
        XCTAssertFalse(sessions[0].hookWired)
        XCTAssertEqual(sessions[0].tmuxPaneID, "%1")
    }

    func testEnumeratorFallsBackToProcessTreeWhenTTYLookupFails() {
        // If `ps -t` fails outright (unusual, but should degrade gracefully),
        // fall back to walking the process tree rooted at pane_pid.
        let panePid = 28734
        let paneTTY = "/dev/ttys003"
        let claudeArgv = "/opt/homebrew/Caskroom/claude-code@latest/2.1.195/claude"

        let executor = FakeProcessCommandExecutor(results: [
            Self.listPanesKey: .success("mysession\tmywindow\t\(panePid)\t\(paneTTY)\t/Users/oliver/code\t1751000000\t%2\n"),
            "ps -t ttys003 -o pid=,args=": .failure(
                ProcessCommandFailure(executable: "ps", arguments: [], exitCode: 1, stderr: "no such tty")
            ),
            // Fallback: pane_pid itself is claude (direct, no daemon detachment).
            "ps -p \(panePid) -o args=": .success(claudeArgv),
            "tmux show-environment -t mysession AGENT_WRAPPED_SESSION_ID": .failure(
                ProcessCommandFailure(executable: "tmux", arguments: [], exitCode: 1, stderr: "unknown variable")
            )
        ])

        let enumerator = AllClaudeSessionEnumerator(
            executor: executor,
            now: { Date(timeIntervalSince1970: 1_751_000_000) }
        )
        let sessions = enumerator.enumerateAll()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].tmuxSessionName, "mysession")
    }

    /// Regression test: `#{pane_activity}` is empty on a freshly-created tmux pane,
    /// which puts a trailing tab at the end of the list-panes line. Trimming with
    /// `.whitespacesAndNewlines` (which includes tab) ate that trailing delimiter and
    /// silently collapsed 6 tab-separated fields to 5, failing the field-count guard
    /// with no log line — the actual live bug that made discovery report 0 sessions
    /// despite tmux having a real claude pane.
    func testEnumeratorHandlesEmptyTrailingActivityField() {
        let panePid = 28734
        let paneTTY = "/dev/ttys003"
        // Note: no timestamp after the tab — this is the exact shape tmux emits
        // for a pane with no recorded activity yet. pane_id (%3) is still present.
        let lineWithEmptyActivity = "mysession\tmywindow\t\(panePid)\t\(paneTTY)\t/Users/oliver/code\t\t%3"

        let executor = FakeProcessCommandExecutor(results: [
            Self.listPanesKey: .success(lineWithEmptyActivity + "\n"),
            "ps -t ttys003 -o pid=,args=": .success("\(panePid) -zsh\n54156 claude --allow-dangerously-skip-permissions\n"),
            "tmux show-environment -t mysession AGENT_WRAPPED_SESSION_ID": .failure(
                ProcessCommandFailure(executable: "tmux", arguments: [], exitCode: 1, stderr: "unknown variable")
            )
        ])

        let enumerator = AllClaudeSessionEnumerator(
            executor: executor,
            now: { Date(timeIntervalSince1970: 1_751_000_000) }
        )
        let sessions = enumerator.enumerateAll()

        XCTAssertEqual(sessions.count, 1, "empty trailing pane_activity field must not break field-count parsing")
        XCTAssertEqual(sessions[0].tmuxSessionName, "mysession")
    }

    func testEnumeratorSkipsSessionWithNoClaudeOnTTYOrTree() {
        let panePid = 99999
        let paneTTY = "/dev/ttys009"
        let executor = FakeProcessCommandExecutor(results: [
            Self.listPanesKey: .success("mysession\tmywindow\t\(panePid)\t\(paneTTY)\t/Users/oliver/code\t1751000000\t%4\n"),
            // ps -t finds only a shell, no claude.
            "ps -t ttys009 -o pid=,args=": .success("\(panePid) -zsh\n"),
            // Fallback tree walk: pane_pid itself is zsh, no children.
            "ps -p \(panePid) -o args=": .success("-zsh"),
            "pgrep -P \(panePid)": .failure(
                ProcessCommandFailure(executable: "pgrep", arguments: [], exitCode: 1, stderr: "")
            )
        ])

        let enumerator = AllClaudeSessionEnumerator(
            executor: executor,
            now: { Date(timeIntervalSince1970: 1_751_000_000) }
        )
        let sessions = enumerator.enumerateAll()
        XCTAssertEqual(sessions.count, 0)
    }
}
