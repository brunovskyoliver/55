import AgentShared
import Foundation

public protocol ApprovalDecisionSending: Sendable {
    func sendApprovalDecision(_ decision: ApprovalRequestDecision, to session: AttachedSession) throws
}

public enum ApprovalDecisionError: Error, Equatable, Sendable {
    case noActiveSession
    case noPendingApprovalRequest
    case staleRequest
    case duplicateDecision
    case decisionSendFailed(String)

    var apiErrorCode: String {
        switch self {
        case .noActiveSession:
            return "active_agent_session_required"
        case .noPendingApprovalRequest:
            return "approval_request_required"
        case .staleRequest:
            return "approval_request_stale"
        case .duplicateDecision:
            return "approval_decision_duplicate"
        case .decisionSendFailed:
            return "approval_decision_failed"
        }
    }

    var userMessage: String {
        switch self {
        case .noActiveSession:
            return "A Wrapped Session must be active before deciding an approval request."
        case .noPendingApprovalRequest:
            return "There is no approval request to decide."
        case .staleRequest:
            return "That approval request is no longer pending."
        case .duplicateDecision:
            return "That approval request was already decided."
        case .decisionSendFailed(let detail):
            return detail.isEmpty ? "The approval decision could not be sent to the Wrapped Session." : detail
        }
    }
}

public struct TmuxApprovalDecisionSender: ApprovalDecisionSending {
    private let executor: any ProcessCommandExecuting

    public init(executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor()) {
        self.executor = executor
    }

    public func sendApprovalDecision(_ decision: ApprovalRequestDecision, to session: AttachedSession) throws {
        guard let tmuxAttachment = session.session.tmuxAttachment else {
            throw ApprovalDecisionError.decisionSendFailed("The active Wrapped Session has no tmux attachment.")
        }

        let reply = switch decision {
        case .approve:
            "y"
        case .deny:
            "n"
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
            throw ApprovalDecisionError.decisionSendFailed(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as ApprovalDecisionError {
            throw error
        } catch {
            throw ApprovalDecisionError.decisionSendFailed(String(describing: error))
        }
    }
}
