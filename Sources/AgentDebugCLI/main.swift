import AgentShared
import Foundation
import MacAgentCore

// A small CLI for exercising the Mac Agent's discovery/focus logic directly from the
// terminal, without going through the GUI app. Useful for fast iteration when debugging
// session discovery or Ghostty/tmux focus issues — run the exact same code paths the
// app uses, see raw command output immediately, no rebuild-relaunch-click cycle.
//
// Usage:
//   swift run agent-debug scan                    list all discoverable Claude sessions
//   swift run agent-debug raw-panes                dump raw tmux list-panes fields
//   swift run agent-debug ps-tty <tty>              dump `ps -t <tty>` (e.g. ttys003)
//   swift run agent-debug claude-check <pid>        test isClaudeCodeArgv against a live pid's argv
//   swift run agent-debug focus <sessionID>         focus/attach a discovered session by id

let executor = FoundationProcessCommandExecutor()

func printUsage() {
    print("""
    agent-debug — Mac Agent discovery/focus debug CLI

    Commands:
      scan                    List all discoverable Claude sessions (same logic as the app)
      raw-panes                Dump raw tmux list-panes fields (session, window, pid, tty, cwd, activity)
      ps-tty <tty>              Dump `ps -t <tty> -o pid=,args=` (e.g. ttys003 or /dev/ttys003)
      claude-check <pid>        Run isClaudeCodeArgv against a live pid's argv and print the verdict
      focus <sessionID>         Focus/attach a discovered session (by the id printed by `scan`)
    """)
}

func runScan() {
    print("Scanning for Claude sessions (AllClaudeSessionEnumerator)...\n")
    let enumerator = AllClaudeSessionEnumerator(executor: executor)
    let sessions = enumerator.enumerateAll()

    // Print the internal AgentLog trail so we can see exactly what the enumerator
    // decided at each step, without needing the GUI app.
    print("--- internal log trail ---")
    for entry in AgentLogStore.shared.entries {
        print("[\(entry.category.rawValue)] \(entry.message)")
    }
    print("---------------------------\n")

    if sessions.isEmpty {
        print("No sessions found.")
        return
    }

    for s in sessions {
        print("id:         \(s.id)")
        print("kind:       \(s.kind.rawValue)")
        print("tmux:       \(s.tmuxSessionName ?? "-") / \(s.tmuxWindowName ?? "-")")
        print("repoPath:   \(s.repoPath)")
        print("lastActive: \(s.lastActivity)")
        print("hookWired:  \(s.hookWired)")
        print("---")
    }
    print("\nTotal: \(sessions.count) session(s)")
}

func runRawPanes() {
    print("Running: tmux list-panes -a -F '#{session_name}\\t#{window_name}\\t#{pane_pid}\\t#{pane_tty}\\t#{pane_current_path}\\t#{pane_activity}\\t#{pane_current_command}'\n")
    do {
        let result = try executor.run(
            executable: "tmux",
            arguments: [
                "list-panes", "-a",
                "-F", "#{session_name}\t#{window_name}\t#{pane_pid}\t#{pane_tty}\t#{pane_current_path}\t#{pane_activity}\t#{pane_current_command}"
            ]
        )
        let text = String(decoding: result.stdout, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("(no panes — tmux server not running or no sessions)")
        } else {
            print(text)
        }
    } catch {
        print("tmux list-panes failed: \(error)")
    }
}

func runPsTTY(_ tty: String) {
    let deviceName = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
    print("Running: ps -t \(deviceName) -o pid=,ppid=,args=\n")
    do {
        let result = try executor.run(
            executable: "ps",
            arguments: ["-t", deviceName, "-o", "pid=,ppid=,args="]
        )
        let text = String(decoding: result.stdout, as: UTF8.self)
        print(text.isEmpty ? "(no processes on that tty)" : text)
    } catch {
        print("ps -t \(deviceName) failed: \(error)")
    }
}

func runClaudeCheck(_ pidStr: String) {
    guard let pid = Int(pidStr) else {
        print("Not a valid pid: \(pidStr)")
        return
    }
    do {
        let result = try executor.run(executable: "ps", arguments: ["-p", "\(pid)", "-o", "args="])
        let args = String(decoding: result.stdout, as: UTF8.self)
        print("argv: \(args.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("isClaudeCodeArgv: \(isClaudeCodeArgv(args))")
    } catch {
        print("ps -p \(pid) failed: \(error)")
    }
}

func runFocus(_ sessionID: String) {
    let enumerator = AllClaudeSessionEnumerator(executor: executor)
    let sessions = enumerator.enumerateAll()
    guard let session = sessions.first(where: { $0.id == sessionID }) else {
        print("Session '\(sessionID)' not found. Run `scan` first to list ids.")
        return
    }

    guard let sessionName = session.tmuxSessionName else {
        print("Session has no tmux session name (bare Ghostty kind); focus not supported from CLI yet.")
        return
    }
    let windowName = session.tmuxWindowName ?? "claude"
    let attachCommand = "tmux attach-session -t \(sessionName)"

    print("Focusing session '\(sessionID)' → tmux \(sessionName):\(windowName)...")
    let launcher = GhosttyLauncher(executor: executor)
    if let warning = launcher.focusWithAeroSpaceIfAvailable(
        attachCommand: attachCommand,
        sessionName: sessionName,
        windowName: windowName
    ) {
        print("Warning: \(warning)")
    } else {
        print("Focus succeeded.")
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    printUsage()
    exit(1)
}

switch command {
case "scan":
    runScan()
case "raw-panes":
    runRawPanes()
case "ps-tty":
    guard arguments.count > 1 else { print("Usage: agent-debug ps-tty <tty>"); exit(1) }
    runPsTTY(arguments[1])
case "claude-check":
    guard arguments.count > 1 else { print("Usage: agent-debug claude-check <pid>"); exit(1) }
    runClaudeCheck(arguments[1])
case "focus":
    guard arguments.count > 1 else { print("Usage: agent-debug focus <sessionID>"); exit(1) }
    runFocus(arguments[1])
default:
    printUsage()
    exit(1)
}
