import AgentShared
#if canImport(AppKit)
import AppKit
#endif
import Foundation

// MARK: - Legacy narrow-discovery protocol (agent-launched only)

public protocol WrappedSessionDiscovering: Sendable {
    /// Search for an existing managed Wrapped Session. Returns the first match, or nil.
    func findExistingSession() -> DiscoveredSession?
}

// MARK: - Claude process argv helpers (module-private)

/// Returns true if `args` (the full argv string from ps) is a Claude Code CLI invocation.
///
/// Claude Code 2.x ships as a native binary — no "node" in the argv. Matching on basename
/// "claude" is authoritative: the binary lives at paths like
/// `/opt/homebrew/Caskroom/claude-code@latest/<version>/claude`.
/// We deliberately exclude the Claude.app GUI helper processes whose argv contains
/// "Claude Helper" (capital C, different token) and never the bare `claude` basename.
public func isClaudeCodeArgv(_ args: String) -> Bool {
    // Accept the bare command name "claude" (e.g. pane_current_command == claude).
    if args.trimmingCharacters(in: .whitespacesAndNewlines) == "claude" { return true }

    // Accept "/path/to/claude" as the first space-delimited token.
    let firstToken = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        .first
        .map(String.init) ?? ""

    // The token must end with "/claude" (basename match).
    return firstToken.hasSuffix("/claude") || firstToken == "claude"
}

// MARK: - Legacy narrow-discovery result

/// A Wrapped Session found in tmux that was originally launched by this Mac Agent.
public struct DiscoveredSession: Sendable {
    public var wrappedSessionID: String
    public var tmuxSessionName: String
    public var tmuxWindowName: String

    public init(wrappedSessionID: String, tmuxSessionName: String, tmuxWindowName: String) {
        self.wrappedSessionID = wrappedSessionID
        self.tmuxSessionName = tmuxSessionName
        self.tmuxWindowName = tmuxWindowName
    }
}

// MARK: - Broad discovery protocol (all running Claude sessions)

public protocol ClaudeSessionEnumerating: Sendable {
    /// Enumerate all currently running Claude Code sessions visible on this Mac.
    /// Includes agent-launched, external tmux, and bare Ghostty sessions.
    func enumerateAll() -> [DiscoverableSession]
}

// MARK: - tmux-based narrow discoverer (legacy)

/// Discovers existing Wrapped Sessions by:
/// 1. Listing tmux sessions whose name starts with "agent-" (our launch prefix).
/// 2. Probing `AGENT_WRAPPED_SESSION_ID` from the tmux session env (D2 correlation key).
/// 3. Running a liveness check (`capture-pane` succeeds → pane alive).
///
/// **Important:** does NOT match on `pane_current_command` — the env probe is authoritative.
public struct TmuxWrappedSessionDiscoverer: WrappedSessionDiscovering {
    private let executor: any ProcessCommandExecuting

    public init(executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor()) {
        self.executor = executor
    }

    public func findExistingSession() -> DiscoveredSession? {
        // 1. List tmux sessions
        guard let result = try? executor.run(
            executable: "tmux",
            arguments: ["list-sessions", "-F", "#{session_name}"]
        ) else { return nil }

        let sessionNames = String(decoding: result.stdout, as: UTF8.self)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("agent-") && !$0.isEmpty }

        // 2. Probe each candidate
        for name in sessionNames {
            if let session = verify(sessionName: name) {
                return session
            }
        }
        return nil
    }

    // MARK: - Private

    private func verify(sessionName: String) -> DiscoveredSession? {
        // Probe AGENT_WRAPPED_SESSION_ID from the tmux session environment.
        // Format returned by tmux: "AGENT_WRAPPED_SESSION_ID=<value>"
        guard let envResult = try? executor.run(
            executable: "tmux",
            arguments: ["show-environment", "-t", sessionName, "AGENT_WRAPPED_SESSION_ID"]
        ) else { return nil }

        let envLine = String(decoding: envResult.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = "AGENT_WRAPPED_SESSION_ID="
        guard envLine.hasPrefix(prefix) else { return nil }

        let wrappedSessionID = String(envLine.dropFirst(prefix.count))
        guard !wrappedSessionID.isEmpty else { return nil }

        // Liveness check: capture-pane must succeed (pane must exist and be alive).
        guard (try? executor.run(
            executable: "tmux",
            arguments: ["capture-pane", "-p", "-t", sessionName]
        )) != nil else { return nil }

        // Get the active window name.
        let windowName: String
        if let winResult = try? executor.run(
            executable: "tmux",
            arguments: ["display-message", "-t", sessionName, "-p", "#{window_name}"]
        ) {
            windowName = String(decoding: winResult.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            windowName = "claude"
        }

        return DiscoveredSession(
            wrappedSessionID: wrappedSessionID,
            tmuxSessionName: sessionName,
            tmuxWindowName: windowName
        )
    }
}

// MARK: - Broad enumerator

/// Enumerates ALL running Claude Code sessions on this Mac — agent-launched and external.
///
/// **Strategy:**
/// - **tmux:** `tmux list-panes -a` to get every pane. For each pane, check the `pane_pid`
///   itself and then walk its subtree with `pgrep -P` / `ps -o args=` looking for a `claude`
///   invocation in argv. Claude Code 2.x ships as a native binary (no "node" in argv); argv
///   basename matching is authoritative. Probe `AGENT_WRAPPED_SESSION_ID` to classify
///   agent-launched vs external.
/// - **bare Ghostty:** enumerate Ghostty's NSRunningApplication children via `pgrep -P` and
///   match on `claude` in argv. Mark `.bareGhostty`, hookWired:false.
///
/// Sessions with an unknown cwd are still surfaced with `repoPath == ""` so the picker can
/// show them. Detection is heuristic; false positives are non-harmful (user can dismiss).
public struct AllClaudeSessionEnumerator: ClaudeSessionEnumerating {
    private let executor: any ProcessCommandExecuting
    private let now: @Sendable () -> Date

    public init(
        executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.executor = executor
        self.now = now
    }

    public func enumerateAll() -> [DiscoverableSession] {
        let tmuxSessions = enumerateTmuxSessions()
        let bareSessions = enumerateBareGhostty(alreadyFoundTmuxNames: Set(tmuxSessions.compactMap { $0.tmuxSessionName }))
        return deduplicated(tmuxSessions + bareSessions)
    }

    // MARK: - tmux enumeration

    private func enumerateTmuxSessions() -> [DiscoverableSession] {
        // Format: session_name \t window_name \t pane_pid \t pane_tty \t pane_current_path \t pane_activity \t pane_id
        // pane_activity is unix epoch seconds; pane_id is the stable %N identifier (survives respawn-pane).
        do {
            let result = try executor.run(
                executable: "tmux",
                arguments: [
                    "list-panes", "-a",
                    "-F", "#{session_name}\t#{window_name}\t#{pane_pid}\t#{pane_tty}\t#{pane_current_path}\t#{pane_activity}\t#{pane_id}"
                ]
            )
            // Trim only newline characters, not all whitespace — the format string ends
            // with #{pane_activity}, which is empty on a freshly-created pane. Trimming
            // .whitespacesAndNewlines would eat the trailing tab delimiting that empty
            // field, silently collapsing 6 tab-separated fields into 5 and breaking the
            // field-count guard below with no error (the classic bug that caused
            // discovery to report 0 sessions despite tmux having live claude panes).
            let lines = String(decoding: result.stdout, as: UTF8.self)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .newlines) }
                .filter { !$0.isEmpty }
            agentLog("[Discovery] tmux list-panes returned \(lines.count) pane(s)", category: .discovery)
            return parseDiscoverableSessions(from: lines)
        } catch {
            agentLog("[Discovery] tmux list-panes failed: \(error)", category: .discovery)
            return []
        }
    }

    private func parseDiscoverableSessions(from lines: [String]) -> [DiscoverableSession] {
        // Process once per session (first matching pane wins).
        var seenSessionNames = Set<String>()
        var sessions: [DiscoverableSession] = []

        for line in lines {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 6 else { continue }

            let sessionName = parts[0]
            let windowName = parts[1]
            let panePidStr = parts[2]
            let paneTTY = parts[3]
            let paneCwd = parts[4]
            let paneActivityStr = parts[5]
            let paneID = parts.count >= 7 ? parts[6].trimmingCharacters(in: .whitespacesAndNewlines) : nil

            guard !seenSessionNames.contains(sessionName) else { continue }

            let panePid = Int(panePidStr) ?? 0

            // Primary: match by TTY. Claude Code's background-daemon architecture
            // (`--bg-pty-host`) detaches the actual claude process from the pane's
            // process tree entirely — it takes over the pane's PTY directly without
            // being a descendant of pane_pid, so pgrep -P style tree-walking can
            // never find it. `ps -t <tty>` lists every process attached to that
            // terminal regardless of parent-child lineage, so it's authoritative.
            // Fallback: walk the process tree rooted at pane_pid (covers cases
            // where claude was launched directly with no daemon detachment and
            // the TTY lookup is unavailable for some reason).
            let claudePid = claudePidOnTTY(paneTTY) ?? claudePidInSubtree(rootPid: panePid)

            guard let claudePid else {
                agentLog("[Discovery] session '\(sessionName)' pane_pid=\(panePid) tty=\(paneTTY): no claude process found", category: .discovery)
                continue
            }
            agentLog("[Discovery] session '\(sessionName)' matched claude pid=\(claudePid) via tty=\(paneTTY)", category: .discovery)

            seenSessionNames.insert(sessionName)

            // Prefer pane_current_path; fall back to lsof on the claude pid.
            let cwd = paneCwd.isEmpty ? cwdViaLsof(pid: claudePid) : paneCwd

            let activity: Date
            if let epoch = TimeInterval(paneActivityStr) {
                activity = Date(timeIntervalSince1970: epoch)
            } else {
                activity = now()
            }

            // Classify by AGENT_WRAPPED_SESSION_ID presence.
            let cleanPaneID = paneID.flatMap { $0.isEmpty ? nil : $0 }
            if let agentID = probeWrappedSessionID(sessionName: sessionName) {
                sessions.append(DiscoverableSession(
                    id: agentID,
                    kind: .agentLaunched,
                    tmuxSessionName: sessionName,
                    tmuxWindowName: windowName,
                    tmuxPaneID: cleanPaneID,
                    repoPath: cwd,
                    lastActivity: activity,
                    hookWired: true
                ))
            } else {
                sessions.append(DiscoverableSession(
                    id: "tmux:\(sessionName)",
                    kind: .externalTmux,
                    tmuxSessionName: sessionName,
                    tmuxWindowName: windowName,
                    tmuxPaneID: cleanPaneID,
                    repoPath: cwd,
                    lastActivity: activity,
                    hookWired: false
                ))
            }
        }

        agentLog("[Discovery] found \(sessions.count) Claude session(s) in tmux", category: .discovery)
        return sessions
    }

    // MARK: - Bare Ghostty enumeration

    private func enumerateBareGhostty(alreadyFoundTmuxNames: Set<String>) -> [DiscoverableSession] {
        #if canImport(AppKit)
        let ghosttyApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
        guard !ghosttyApps.isEmpty else {
            agentLog("[Discovery] Ghostty not running — skipping bare Ghostty scan", category: .discovery)
            return []
        }

        var sessions: [DiscoverableSession] = []
        var seenPids = Set<Int>()

        for app in ghosttyApps {
            let appPid = Int(app.processIdentifier)
            agentLog("[Discovery] scanning Ghostty app pid=\(appPid) for bare claude descendants", category: .discovery)
            for pid in claudeDescendants(ofPid: appPid) {
                guard !seenPids.contains(pid) else { continue }
                seenPids.insert(pid)
                let cwd = cwdViaLsof(pid: pid)
                agentLog("[Discovery] bare Ghostty claude pid=\(pid) cwd=\(cwd.isEmpty ? "(unknown)" : cwd)", category: .discovery)
                sessions.append(DiscoverableSession(
                    id: "ghostty:\(pid)",
                    kind: .bareGhostty,
                    tmuxSessionName: nil,
                    tmuxWindowName: nil,
                    repoPath: cwd,
                    lastActivity: now(),
                    hookWired: false
                ))
            }
        }

        return sessions
        #else
        return []
        #endif
    }

    // MARK: - Process helpers

    /// Returns the pid of a claude process attached to `tty` (tmux's `#{pane_tty}`, e.g.
    /// "/dev/ttys003"), or nil if none is found or `tty` is empty.
    ///
    /// Claude Code's background-daemon architecture can detach the real claude process
    /// from the tmux pane's process tree — it takes ownership of the pane's PTY directly
    /// without remaining a descendant of `pane_pid`. `ps -t <tty>` enumerates every
    /// process attached to a terminal device regardless of parent-child lineage, so it
    /// finds these daemon-owned sessions that process-tree walking (pgrep -P) cannot.
    private func claudePidOnTTY(_ tty: String) -> Int? {
        guard !tty.isEmpty else { return nil }
        // tmux reports "/dev/ttysNNN"; `ps -t` wants the bare device name "ttysNNN".
        let deviceName = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty

        guard let r = try? executor.run(
            executable: "ps",
            arguments: ["-t", deviceName, "-o", "pid=,args="]
        ) else { return nil }

        let lines = String(decoding: r.stdout, as: UTF8.self)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            guard let spaceIndex = line.firstIndex(of: " ") else { continue }
            guard let pid = Int(line[..<spaceIndex]) else { continue }
            let args = String(line[line.index(after: spaceIndex)...])
            if isClaudeCodeArgv(args) { return pid }
        }
        return nil
    }

    /// Returns the pid of the first claude process at `rootPid` or in its subtree (up to 4 levels).
    /// Checks `rootPid` itself first (handles the case where claude IS the pane process).
    private func claudePidInSubtree(rootPid: Int) -> Int? {
        guard rootPid > 0 else { return nil }

        // Check root itself.
        if isClaudePid(rootPid) { return rootPid }

        // BFS up to 4 levels deep.
        var frontier = [rootPid]
        for _ in 0 ..< 4 {
            var nextFrontier: [Int] = []
            for parent in frontier {
                for child in directChildren(of: parent) {
                    if isClaudePid(child) { return child }
                    nextFrontier.append(child)
                }
            }
            if nextFrontier.isEmpty { break }
            frontier = nextFrontier
        }
        return nil
    }

    /// Returns pids of all `claude` argv processes in the subtree rooted at `pid`.
    /// Used by the bare-Ghostty enumeration path (may find multiple claude pids).
    private func claudeDescendants(ofPid pid: Int) -> [Int] {
        guard pid > 0 else { return [] }
        if isClaudePid(pid) { return [pid] }
        var found: [Int] = []
        var frontier = [pid]
        for _ in 0 ..< 4 {
            var nextFrontier: [Int] = []
            for parent in frontier {
                for child in directChildren(of: parent) {
                    if isClaudePid(child) {
                        found.append(child)
                    } else {
                        nextFrontier.append(child)
                    }
                }
            }
            if nextFrontier.isEmpty { break }
            frontier = nextFrontier
        }
        return found
    }

    private func directChildren(of parent: Int) -> [Int] {
        guard let r = try? executor.run(
            executable: "pgrep",
            arguments: ["-P", "\(parent)"]
        ) else { return [] }
        return String(decoding: r.stdout, as: UTF8.self)
            .components(separatedBy: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
    }

    private func isClaudePid(_ pid: Int) -> Bool {
        guard let r = try? executor.run(
            executable: "ps",
            arguments: ["-p", "\(pid)", "-o", "args="]
        ) else { return false }
        let args = String(decoding: r.stdout, as: UTF8.self)
        return isClaudeCodeArgv(args)
    }

    /// Resolve cwd for a process via `lsof -d cwd`; returns "" on failure.
    private func cwdViaLsof(pid: Int) -> String {
        guard pid > 0 else { return "" }
        guard let r = try? executor.run(
            executable: "lsof",
            arguments: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        ) else { return "" }
        // lsof -Fn output: lines beginning with 'n' carry the file name.
        let line = String(decoding: r.stdout, as: UTF8.self)
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("n") }
        return line.map { String($0.dropFirst()) } ?? ""
    }

    /// Probe `AGENT_WRAPPED_SESSION_ID` from the tmux session environment.
    private func probeWrappedSessionID(sessionName: String) -> String? {
        guard let envResult = try? executor.run(
            executable: "tmux",
            arguments: ["show-environment", "-t", sessionName, "AGENT_WRAPPED_SESSION_ID"]
        ) else { return nil }

        let envLine = String(decoding: envResult.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = "AGENT_WRAPPED_SESSION_ID="
        guard envLine.hasPrefix(prefix) else { return nil }
        let value = String(envLine.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    // MARK: - Deduplication

    /// Deduplicate by id; prefer agentLaunched capability over external for same tmux session.
    private func deduplicated(_ sessions: [DiscoverableSession]) -> [DiscoverableSession] {
        var seen = Set<String>()
        // Sort so agentLaunched entries come first, preserving their ids in the de-dup pass.
        let sorted = sessions.sorted { a, b in
            a.kind == .agentLaunched && b.kind != .agentLaunched
        }
        return sorted.filter { seen.insert($0.id).inserted }
    }
}
