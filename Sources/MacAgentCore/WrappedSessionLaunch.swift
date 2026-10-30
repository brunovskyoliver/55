import AgentShared
#if canImport(AppKit)
import AppKit
#endif
import Foundation

public protocol WorktreeBaselineCapturing: Sendable {
    func captureBaseline(repositoryURL: URL) throws -> WorktreeBaselineSummary
}

public protocol TmuxLaunching: Sendable {
    /// Launch a Wrapped Session in tmux.
    /// - Parameters:
    ///   - sessionID: Mac Agent's own session identifier (used in the tmux session name and env).
    ///   - planningArtifact: The attached Planning Artifact.
    ///   - repositoryURL: Working directory for the new tmux window.
    ///   - hookServerPort: When non-zero, installs Claude Code hook shim + exports
    ///     `AGENT_WRAPPED_SESSION_ID` so hook events are delivered to `AgentEventServer`.
    func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL,
        hookServerPort: UInt16
    ) throws -> TmuxLaunchResult
}

/// Re-wrap an existing external tmux session in-place (no new session created).
public protocol TmuxRewrapping: Sendable {
    func rewrapExistingSession(
        sessionID: String,
        tmuxSessionName: String,
        tmuxWindowName: String,
        tmuxPaneID: String?,
        hookServerPort: UInt16
    ) throws -> TmuxRewrapResult
}

public protocol ProcessCommandExecuting: Sendable {
    func run(executable: String, arguments: [String]) throws -> ProcessCommandResult
}

public struct ProcessCommandResult: Equatable, Sendable {
    public var stdout: Data
    public var stderr: String

    public init(stdout: Data, stderr: String = "") {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct ProcessCommandFailure: Error, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var exitCode: Int32
    public var stderr: String

    public init(executable: String, arguments: [String], exitCode: Int32, stderr: String) {
        self.executable = executable
        self.arguments = arguments
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

// MARK: - Launch result

/// The result of a tmux-based Wrapped Session launch, including optional hook wiring details.
public struct TmuxLaunchResult: Sendable {
    public var attachment: TmuxAttachmentInfo
    /// Per-session bearer token embedded in the hook shim; nil when hook server not available.
    public var hookToken: String?

    public init(attachment: TmuxAttachmentInfo, hookToken: String? = nil) {
        self.attachment = attachment
        self.hookToken = hookToken
    }
}

public enum WrappedSessionLaunchError: Error, Equatable, Sendable {
    case noActivePlanningArtifact
    case activeSessionAlreadyRunning(String)
    case baselineCaptureFailed(String)
    case tmuxLaunchFailed(String)
    case attachFailed(String)

    var apiErrorCode: String {
        switch self {
        case .noActivePlanningArtifact:
            return "active_planning_artifact_required"
        case .activeSessionAlreadyRunning:
            return "active_agent_session_conflict"
        case .baselineCaptureFailed:
            return "worktree_baseline_failed"
        case .tmuxLaunchFailed:
            return "tmux_launch_failed"
        case .attachFailed:
            return "session_attach_failed"
        }
    }

    var userMessage: String {
        switch self {
        case .noActivePlanningArtifact:
            return "Attach a Planning Artifact before starting a Wrapped Session."
        case .activeSessionAlreadyRunning:
            return "An Agent Session is already running for this Configured Repository."
        case .baselineCaptureFailed(let detail):
            return detail.isEmpty ? "The Mac Agent could not capture the Worktree Baseline." : detail
        case .tmuxLaunchFailed(let detail):
            return detail.isEmpty ? "The tmux Launcher could not start Claude Code." : detail
        case .attachFailed(let detail):
            return detail.isEmpty ? "The session could not be attached." : detail
        }
    }
}

public struct GitWorktreeBaselineCapturer: WorktreeBaselineCapturing {
    private let executor: any ProcessCommandExecuting
    private let now: @Sendable () -> Date

    public init(
        executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.executor = executor
        self.now = now
    }

    public func captureBaseline(repositoryURL: URL) throws -> WorktreeBaselineSummary {
        do {
            let branch = try gitText(arguments: ["-C", repositoryURL.path, "rev-parse", "--abbrev-ref", "HEAD"])
            let head = try? gitText(arguments: ["-C", repositoryURL.path, "rev-parse", "HEAD"])
            let status = try gitTextPreservingWhitespace(arguments: ["-C", repositoryURL.path, "status", "--porcelain"])
            let changedFiles = parsePorcelainStatus(status)
            let changedFileCount = changedFiles.count
            let shortHead = head.map { String($0.prefix(12)) } ?? "unknown HEAD"
            let isDirty = changedFileCount > 0
            let summary = isDirty
                ? "Dirty worktree: \(changedFileCount) changed file\(changedFileCount == 1 ? "" : "s") on \(branch) at \(shortHead)."
                : "Clean worktree on \(branch) at \(shortHead)."

            return WorktreeBaselineSummary(
                repositoryPath: repositoryURL.path,
                branchName: branch,
                headSHA: head,
                isDirty: isDirty,
                changedFileCount: changedFileCount,
                changedFiles: changedFiles,
                summary: summary,
                capturedAt: now()
            )
        } catch let error as ProcessCommandFailure {
            throw WrappedSessionLaunchError.baselineCaptureFailed(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as WrappedSessionLaunchError {
            throw error
        } catch {
            throw WrappedSessionLaunchError.baselineCaptureFailed(String(describing: error))
        }
    }

    private func gitText(arguments: [String]) throws -> String {
        try gitTextPreservingWhitespace(arguments: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitTextPreservingWhitespace(arguments: [String]) throws -> String {
        let result = try executor.run(executable: "git", arguments: arguments)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func parsePorcelainStatus(_ rawStatus: String) -> [WorktreeBaselineFileChange] {
        rawStatus
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let rawLine = String(line)
                guard rawLine.count >= 4 else {
                    return nil
                }

                let status = String(rawLine.prefix(2))
                let pathText = String(rawLine.dropFirst(3))
                if let range = pathText.range(of: " -> ") {
                    return WorktreeBaselineFileChange(
                        path: String(pathText[range.upperBound...]),
                        previousPath: String(pathText[..<range.lowerBound]),
                        status: status.trimmingCharacters(in: .whitespaces)
                    )
                }

                return WorktreeBaselineFileChange(
                    path: pathText,
                    status: status.trimmingCharacters(in: .whitespaces)
                )
            }
    }
}

/// Launches Claude Code inside a tmux session with optional hook-event wiring.
///
/// When `hookServerPort` is non-zero the launcher:
/// 1. Generates a per-session bearer token via `ClaudeCodeHookTransport`.
/// 2. Writes an ephemeral hook shim + Claude `--settings` JSON to `NSTemporaryDirectory()`.
/// 3. Exports `AGENT_WRAPPED_SESSION_ID` into the tmux session environment so event routing
///    and reuse-discovery work without relying on process-name matching.
/// 4. Launches `claude --settings <file>` instead of bare `claude`.
public struct TmuxClaudeLauncher: TmuxLaunching {
    private let executor: any ProcessCommandExecuting

    public init(executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor()) {
        self.executor = executor
    }

    public func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL,
        hookServerPort: UInt16 = 0
    ) throws -> TmuxLaunchResult {
        let sessionName = sanitizedSessionName(
            "agent-\(planningArtifact.id)-\(String(sessionID.suffix(8)))"
        )
        let windowName = "claude"

        // Optionally generate hook wiring before launching the session.
        var hookToken: String?
        var claudeCommand: [String] = ["claude"]

        if hookServerPort != 0 {
            let token = ClaudeCodeHookTransport.generateToken()
            // Errors writing hook files are non-fatal: fall back to hookless launch.
            if let settingsURL = try? ClaudeCodeHookTransport.writeHookFiles(
                wrappedSessionID: sessionID,
                token: token,
                port: hookServerPort
            ) {
                hookToken = token
                claudeCommand = ["claude", "--settings", settingsURL.path]
            }
        }

        do {
            // Create the tmux session (detached, in the repo directory).
            _ = try executor.run(
                executable: "tmux",
                arguments: [
                    "new-session", "-d",
                    "-s", sessionName,
                    "-n", windowName,
                    "-c", repositoryURL.path,
                ] + claudeCommand
            )

            // Export AGENT_WRAPPED_SESSION_ID so discovery and hook routing can verify identity.
            // This runs after session creation; failure is non-fatal (session is still usable).
            _ = try? executor.run(
                executable: "tmux",
                arguments: [
                    "set-environment",
                    "-t", sessionName,
                    "AGENT_WRAPPED_SESSION_ID",
                    sessionID,
                ]
            )

            let attachment = TmuxAttachmentInfo(
                sessionName: sessionName,
                windowName: windowName,
                attachCommand: "tmux attach-session -t \(sessionName)"
            )
            return TmuxLaunchResult(attachment: attachment, hookToken: hookToken)

        } catch let error as ProcessCommandFailure {
            ClaudeCodeHookTransport.removeHookFiles(wrappedSessionID: sessionID)
            throw WrappedSessionLaunchError.tmuxLaunchFailed(
                error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch let error as WrappedSessionLaunchError {
            ClaudeCodeHookTransport.removeHookFiles(wrappedSessionID: sessionID)
            throw error
        } catch {
            ClaudeCodeHookTransport.removeHookFiles(wrappedSessionID: sessionID)
            throw WrappedSessionLaunchError.tmuxLaunchFailed(String(describing: error))
        }
    }

    private func sanitizedSessionName(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(rawValue.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}

// MARK: - Ghostty Integration

public protocol GhosttyLaunching: Sendable {
    /// Opens or focuses Ghostty on the given tmux session. Non-fatal — failure should
    /// never block a Wrapped Session launch. Returns nil on success, an error message on failure.
    func openOrFocus(attachCommand: String, sessionName: String) -> String?
}

public protocol GhosttyRunningProbing: Sendable {
    func isGhosttyRunning() -> Bool
}

public struct WorkspaceGhosttyRunningProbe: GhosttyRunningProbing {
    public init() {}

    public func isGhosttyRunning() -> Bool {
        #if canImport(AppKit)
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
            .isEmpty == false
        #else
        false
        #endif
    }
}

/// Opens or focuses Ghostty on the managed tmux session.
///
/// Strategy (D7):
/// 1. **If a tmux client is already attached to our session**: switch it in-place with
///    `tmux switch-client`, then AppleScript-activate Ghostty. No new window; no keystroke
///    injection. Avoids duplicating terminal windows or requiring Accessibility permission.
/// 2. **If no tmux client is attached** (Ghostty not running, or no client on our session):
///    open a single fresh Ghostty window with `open -na Ghostty.app --args -e <attach>`.
///
/// This is non-fatal — errors are returned as a warning string rather than thrown.
public struct GhosttyLauncher: GhosttyLaunching {
    private let executor: any ProcessCommandExecuting
    private let runningProbe: any GhosttyRunningProbing

    public init(
        executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor(),
        runningProbe: any GhosttyRunningProbing = WorkspaceGhosttyRunningProbe()
    ) {
        self.executor = executor
        self.runningProbe = runningProbe
    }

    public func openOrFocus(attachCommand: String, sessionName: String) -> String? {
        // 1. Try tmux-native switch if a client is already attached to our session.
        if let clientName = findTmuxClientForSession(sessionName) {
            return switchAndActivate(clientName: clientName, sessionName: sessionName)
        }

        // 2. No attached client — open a fresh Ghostty window.
        return launchFresh(attachCommand: attachCommand)
    }

    // MARK: - Private

    /// Returns the name of the first tmux client attached to `sessionName`, or nil.
    private func findTmuxClientForSession(_ sessionName: String) -> String? {
        guard let result = try? executor.run(
            executable: "tmux",
            arguments: [
                "list-clients",
                "-t", sessionName,
                "-F", "#{client_name}",
            ]
        ) else { return nil }

        let clients = String(decoding: result.stdout, as: UTF8.self)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return clients.first
    }

    /// Switch an existing tmux client to `sessionName` and activate Ghostty.
    private func switchAndActivate(clientName: String, sessionName: String) -> String? {
        // switch-client moves the attached client to our session/window/pane.
        do {
            _ = try executor.run(
                executable: "tmux",
                arguments: ["switch-client", "-c", clientName, "-t", sessionName]
            )
            agentLog("[Focus] tmux switch-client to session '\(sessionName)' via client '\(clientName)': ok", category: .focus)
        } catch let error as ProcessCommandFailure {
            let msg = "tmux switch-client failed: \(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            agentLog("[Focus] \(msg)", category: .focus)
            return msg
        } catch {
            let msg = "tmux switch-client error: \(error)"
            agentLog("[Focus] \(msg)", category: .focus)
            return msg
        }

        // Bring Ghostty to the foreground.
        // Prefer NSRunningApplication.activate (no AppleEvents TCC needed) over osascript.
        #if canImport(AppKit)
        activateGhostty()
        #endif

        return nil
    }

    #if canImport(AppKit)
    /// Activate Ghostty without requiring Automation/AppleEvents TCC consent.
    private func activateGhostty() {
        // Primary: use NSRunningApplication — no special permission needed.
        if let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
            .first
        {
            let result = app.activate(options: [])
            agentLog("[Focus] NSRunningApplication.activate Ghostty: \(result ? "ok" : "failed")", category: .focus)
            if result { return }
        }

        // Fallback: open -a Ghostty (raises the existing instance).
        do {
            _ = try executor.run(executable: "open", arguments: ["-a", "Ghostty"])
            agentLog("[Focus] open -a Ghostty fallback: ok", category: .focus)
        } catch {
            agentLog("[Focus] open -a Ghostty fallback failed: \(error)", category: .focus)
        }
    }
    #endif

    /// Open a single fresh Ghostty window attached to the tmux session.
    private func launchFresh(attachCommand: String) -> String? {
        let parts = attachCommand
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let args = ["-na", "Ghostty.app", "--args", "-e"] + parts
        do {
            _ = try executor.run(executable: "open", arguments: args)
            return nil
        } catch let error as ProcessCommandFailure {
            return "Ghostty launch failed: \(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            return "Ghostty launch error: \(error)"
        }
    }
}

// MARK: - Re-wrap result

/// Result of an in-place re-wrap: the existing tmux session was reused, claude was restarted
/// inside it with `--continue --settings <hookfile>`, and hook wiring was installed.
public struct TmuxRewrapResult: Sendable {
    public var attachment: TmuxAttachmentInfo
    public var hookToken: String?

    public init(attachment: TmuxAttachmentInfo, hookToken: String? = nil) {
        self.attachment = attachment
        self.hookToken = hookToken
    }
}

extension TmuxClaudeLauncher: TmuxRewrapping {
    /// Re-wrap an **existing** external tmux session in-place.
    ///
    /// Uses `tmux respawn-pane -k` to kill the running claude and restart the pane with
    /// `claude --continue --settings <hookfile>` — no new session, no new window.
    /// `--continue` lets Claude Code resume the conversation from its local history.
    ///
    /// - Parameters:
    ///   - sessionID:       New Mac Agent session ID for hook routing and env tagging.
    ///   - tmuxSessionName: Existing tmux session to reuse.
    ///   - tmuxWindowName:  Window/pane to respawn (e.g. "claude" or the window index).
    ///   - hookServerPort:  AgentEventServer port; 0 = hookless fallback.
    public func rewrapExistingSession(
        sessionID: String,
        tmuxSessionName: String,
        tmuxWindowName: String,
        tmuxPaneID: String?,
        hookServerPort: UInt16
    ) throws -> TmuxRewrapResult {
        var hookToken: String?
        var claudeCommand = "claude --continue"

        if hookServerPort != 0 {
            let token = ClaudeCodeHookTransport.generateToken()
            if let settingsURL = try? ClaudeCodeHookTransport.writeHookFiles(
                wrappedSessionID: sessionID,
                token: token,
                port: hookServerPort
            ) {
                hookToken = token
                claudeCommand = "claude --continue --settings \(settingsURL.path)"
            }
        }

        do {
            // respawn-pane -k kills the existing pane process and starts a fresh one.
            // Prefer -t %paneid (stable across respawn) over session:window (hits active pane).
            let paneTarget = tmuxPaneID ?? "\(tmuxSessionName):\(tmuxWindowName)"
            _ = try executor.run(
                executable: "tmux",
                arguments: [
                    "respawn-pane", "-k",
                    "-t", paneTarget,
                    claudeCommand,
                ]
            )

            // Tag the session env so discovery and hook routing work.
            _ = try? executor.run(
                executable: "tmux",
                arguments: [
                    "set-environment",
                    "-t", tmuxSessionName,
                    "AGENT_WRAPPED_SESSION_ID",
                    sessionID,
                ]
            )

            let attachment = TmuxAttachmentInfo(
                sessionName: tmuxSessionName,
                windowName: tmuxWindowName,
                attachCommand: "tmux attach-session -t \(tmuxSessionName)",
                paneID: tmuxPaneID
            )
            return TmuxRewrapResult(attachment: attachment, hookToken: hookToken)

        } catch let error as ProcessCommandFailure {
            ClaudeCodeHookTransport.removeHookFiles(wrappedSessionID: sessionID)
            throw WrappedSessionLaunchError.attachFailed(
                error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            ClaudeCodeHookTransport.removeHookFiles(wrappedSessionID: sessionID)
            throw WrappedSessionLaunchError.attachFailed(String(describing: error))
        }
    }
}

// MARK: - AeroSpace-aware Ghostty focus extension

extension GhosttyLauncher {
    /// Focus Ghostty on a tmux session, using AeroSpace when detected.
    ///
    /// Strategy:
    /// 1. If AeroSpace is running → `aerospace list-windows --all` to find the Ghostty window →
    ///    `aerospace focus --window-id <id>` → `tmux select-window -t <sess>:<win>`.
    /// 2. Else → existing `openOrFocus(attachCommand:sessionName:)`.
    ///
    /// Non-fatal: returns a warning string on any failure.
    public func focusWithAeroSpaceIfAvailable(
        attachCommand: String,
        sessionName: String,
        windowName: String
    ) -> String? {
        #if canImport(AppKit)
        let aeroSpaceRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: "bobko.aerospace")
            .isEmpty == false

        if aeroSpaceRunning {
            return focusViaAeroSpace(sessionName: sessionName, windowName: windowName)
                ?? openOrFocus(attachCommand: attachCommand, sessionName: sessionName)
        }
        #endif
        return openOrFocus(attachCommand: attachCommand, sessionName: sessionName)
    }

    #if canImport(AppKit)
    private func focusViaAeroSpace(sessionName: String, windowName: String) -> String? {
        // List all windows; find the Ghostty one.
        let listResult: ProcessCommandResult
        do {
            listResult = try executor.run(
                executable: "aerospace",
                arguments: ["list-windows", "--all", "--format", "%{window-id}|%{app-name}"]
            )
        } catch {
            agentLog("[Focus] aerospace list-windows failed: \(error) — falling back", category: .focus)
            return "aerospace list-windows failed — falling back"
        }

        let lines = String(decoding: listResult.stdout, as: UTF8.self)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        agentLog("[Focus] aerospace list-windows: \(lines.count) window(s)", category: .focus)

        // Find the first Ghostty window.
        guard let ghosttyLine = lines.first(where: { $0.lowercased().contains("ghostty") }) else {
            agentLog("[Focus] No Ghostty window in AeroSpace layout — falling back", category: .focus)
            return "No Ghostty window in AeroSpace layout — falling back"
        }

        let windowID = ghosttyLine.components(separatedBy: "|").first ?? ""
        guard !windowID.isEmpty else {
            agentLog("[Focus] Could not parse AeroSpace window ID from '\(ghosttyLine)' — falling back", category: .focus)
            return "Could not parse AeroSpace window ID — falling back"
        }

        // Focus the Ghostty window in AeroSpace.
        do {
            _ = try executor.run(
                executable: "aerospace",
                arguments: ["focus", "--window-id", windowID]
            )
            agentLog("[Focus] aerospace focus window-id=\(windowID): ok", category: .focus)
        } catch {
            let msg = "aerospace focus failed: \(error) — falling back"
            agentLog("[Focus] \(msg)", category: .focus)
            return msg
        }

        // Switch the tmux display to our session:window.
        do {
            _ = try executor.run(
                executable: "tmux",
                arguments: ["select-window", "-t", "\(sessionName):\(windowName)"]
            )
            agentLog("[Focus] tmux select-window \(sessionName):\(windowName): ok", category: .focus)
        } catch {
            agentLog("[Focus] tmux select-window \(sessionName):\(windowName) failed: \(error)", category: .focus)
            // Non-fatal — AeroSpace already raised the Ghostty window.
        }

        // Bring Ghostty to the foreground via NSRunningApplication (no TCC needed).
        activateGhostty()

        return nil  // success
    }
    #endif
}

// MARK: - FoundationProcessCommandExecutor

public struct FoundationProcessCommandExecutor: ProcessCommandExecuting {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> ProcessCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

        // Propagate the full environment and augment PATH so Homebrew tools
        // (tmux, aerospace, etc.) resolve correctly when the app is launched
        // from Finder / Xcode / launchd (which provides a minimal PATH).
        var env = ProcessInfo.processInfo.environment
        let homebrew = "/opt/homebrew/bin:/usr/local/bin"
        if let existing = env["PATH"] {
            env["PATH"] = homebrew + ":" + existing
        } else {
            env["PATH"] = homebrew + ":/usr/bin:/bin:/usr/sbin:/sbin"
        }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ProcessCommandFailure(
                executable: executable,
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: errorText
            )
        }

        return ProcessCommandResult(stdout: outputData, stderr: errorText)
    }
}
