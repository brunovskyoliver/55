import AgentShared
import Foundation

public protocol WorktreeBaselineCapturing: Sendable {
    func captureBaseline(repositoryURL: URL) throws -> WorktreeBaselineSummary
}

public protocol TmuxLaunching: Sendable {
    func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL
    ) throws -> TmuxAttachmentInfo
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

public enum WrappedSessionLaunchError: Error, Equatable, Sendable {
    case noActivePlanningArtifact
    case activeSessionAlreadyRunning(String)
    case baselineCaptureFailed(String)
    case tmuxLaunchFailed(String)

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
            let status = try gitText(arguments: ["-C", repositoryURL.path, "status", "--porcelain"])
            let changedFileCount = status
                .split(separator: "\n", omittingEmptySubsequences: true)
                .count
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
        let result = try executor.run(executable: "git", arguments: arguments)
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TmuxClaudeLauncher: TmuxLaunching {
    private let executor: any ProcessCommandExecuting

    public init(executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor()) {
        self.executor = executor
    }

    public func launchWrappedSession(
        sessionID: String,
        planningArtifact: PlanningArtifact,
        repositoryURL: URL
    ) throws -> TmuxAttachmentInfo {
        let sessionName = sanitizedSessionName("agent-\(planningArtifact.id)-\(String(sessionID.suffix(8)))")
        let windowName = "claude"

        do {
            _ = try executor.run(
                executable: "tmux",
                arguments: [
                    "new-session",
                    "-d",
                    "-s",
                    sessionName,
                    "-n",
                    windowName,
                    "-c",
                    repositoryURL.path,
                    "claude"
                ]
            )

            return TmuxAttachmentInfo(
                sessionName: sessionName,
                windowName: windowName,
                attachCommand: "tmux attach-session -t \(sessionName)"
            )
        } catch let error as ProcessCommandFailure {
            throw WrappedSessionLaunchError.tmuxLaunchFailed(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as WrappedSessionLaunchError {
            throw error
        } catch {
            throw WrappedSessionLaunchError.tmuxLaunchFailed(String(describing: error))
        }
    }

    private func sanitizedSessionName(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(rawValue.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}

public struct FoundationProcessCommandExecutor: ProcessCommandExecuting {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> ProcessCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

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
