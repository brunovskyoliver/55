import AgentShared
import Foundation

public protocol WrappedSessionInputSending: Sendable {
    func sendReply(_ reply: String, to session: AttachedSession) throws
}

public enum PendingInputReplyError: Error, Equatable, Sendable {
    case noActiveSession
    case noPendingInput
    case uncertainInputRequiresConfirmation
    case emptyReply
    case inputSendFailed(String)

    var apiErrorCode: String {
        switch self {
        case .noActiveSession:
            return "active_agent_session_required"
        case .noPendingInput:
            return "pending_input_required"
        case .uncertainInputRequiresConfirmation:
            return "uncertain_pending_input_confirmation_required"
        case .emptyReply:
            return "pending_input_reply_empty"
        case .inputSendFailed:
            return "pending_input_reply_failed"
        }
    }

    var userMessage: String {
        switch self {
        case .noActiveSession:
            return "A Wrapped Session must be active before replying."
        case .noPendingInput:
            return "There is no Pending Input to reply to."
        case .uncertainInputRequiresConfirmation:
            return "Uncertain Pending Input requires extra confirmation before sending."
        case .emptyReply:
            return "Reply text cannot be empty."
        case .inputSendFailed(let detail):
            return detail.isEmpty ? "The reply could not be sent to the Wrapped Session." : detail
        }
    }
}

public struct TmuxWrappedSessionInputSender: WrappedSessionInputSending {
    private let executor: any ProcessCommandExecuting

    public init(executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor()) {
        self.executor = executor
    }

    public func sendReply(_ reply: String, to session: AttachedSession) throws {
        guard let tmuxAttachment = session.session.tmuxAttachment else {
            throw PendingInputReplyError.inputSendFailed("The active Wrapped Session has no tmux attachment.")
        }

        let target = tmuxAttachment.paneID ?? tmuxAttachment.sessionName
        do {
            _ = try executor.run(
                executable: "tmux",
                arguments: ["send-keys", "-t", target, "-l", reply]
            )
            _ = try executor.run(
                executable: "tmux",
                arguments: ["send-keys", "-t", target, "Enter"]
            )
        } catch let error as ProcessCommandFailure {
            throw PendingInputReplyError.inputSendFailed(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as PendingInputReplyError {
            throw error
        } catch {
            throw PendingInputReplyError.inputSendFailed(String(describing: error))
        }
    }
}
