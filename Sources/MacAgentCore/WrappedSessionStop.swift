import AgentShared
import Foundation

public protocol WrappedSessionStopping: Sendable {
    func stopWrappedSession(_ session: AttachedSession) throws -> WrappedSessionStopResult
}

public enum WrappedSessionStopMethod: String, Equatable, Sendable {
    case gracefulInterrupt
    case terminationFallback
}

public struct WrappedSessionStopResult: Equatable, Sendable {
    public var method: WrappedSessionStopMethod
    public var summary: String

    public init(method: WrappedSessionStopMethod, summary: String) {
        self.method = method
        self.summary = summary
    }
}

public enum WrappedSessionStopError: Error, Equatable, Sendable {
    case noActiveSession
    case confirmationRequired
    case stopFailed(String)

    var apiErrorCode: String {
        switch self {
        case .noActiveSession:
            return "active_agent_session_required"
        case .confirmationRequired:
            return "guarded_stop_confirmation_required"
        case .stopFailed:
            return "guarded_stop_failed"
        }
    }

    var userMessage: String {
        switch self {
        case .noActiveSession:
            return "A Wrapped Session must be active before stopping."
        case .confirmationRequired:
            return "Guarded Stop requires explicit Owner Device confirmation."
        case .stopFailed(let detail):
            return detail.isEmpty ? "The Wrapped Session could not be stopped." : detail
        }
    }
}

public struct TmuxWrappedSessionStopper: WrappedSessionStopping {
    private let executor: any ProcessCommandExecuting
    private let gracefulCheckAttempts: Int
    private let gracefulCheckInterval: TimeInterval

    public init(
        executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor(),
        gracefulCheckAttempts: Int = 4,
        gracefulCheckInterval: TimeInterval = 0.5
    ) {
        self.executor = executor
        self.gracefulCheckAttempts = max(1, gracefulCheckAttempts)
        self.gracefulCheckInterval = max(0, gracefulCheckInterval)
    }

    public func stopWrappedSession(_ session: AttachedSession) throws -> WrappedSessionStopResult {
        guard let tmuxAttachment = session.session.tmuxAttachment else {
            throw WrappedSessionStopError.stopFailed("The active Wrapped Session has no tmux attachment.")
        }

        do {
            _ = try executor.run(
                executable: "tmux",
                arguments: ["send-keys", "-t", tmuxAttachment.sessionName, "C-c"]
            )

            for attempt in 0..<gracefulCheckAttempts {
                if !tmuxSessionExists(tmuxAttachment.sessionName) {
                    return WrappedSessionStopResult(
                        method: .gracefulInterrupt,
                        summary: "The Wrapped Session stopped after a graceful interrupt."
                    )
                }

                if attempt < gracefulCheckAttempts - 1, gracefulCheckInterval > 0 {
                    Thread.sleep(forTimeInterval: gracefulCheckInterval)
                }
            }

            _ = try executor.run(
                executable: "tmux",
                arguments: ["kill-session", "-t", tmuxAttachment.sessionName]
            )

            guard !tmuxSessionExists(tmuxAttachment.sessionName) else {
                throw WrappedSessionStopError.stopFailed("tmux session \(tmuxAttachment.sessionName) is still running after termination fallback.")
            }

            return WrappedSessionStopResult(
                method: .terminationFallback,
                summary: "The Wrapped Session required termination fallback after graceful interrupt did not stop it."
            )
        } catch let error as WrappedSessionStopError {
            throw error
        } catch let error as ProcessCommandFailure {
            throw WrappedSessionStopError.stopFailed(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw WrappedSessionStopError.stopFailed(String(describing: error))
        }
    }

    private func tmuxSessionExists(_ sessionName: String) -> Bool {
        do {
            _ = try executor.run(executable: "tmux", arguments: ["has-session", "-t", sessionName])
            return true
        } catch {
            return false
        }
    }
}
