import AgentShared
import Foundation

public protocol GitHubCommentPosting: Sendable {
    func postGeneralComment(_ body: String, to artifact: PlanningArtifact) throws -> GitHubCommentPostResult
}

public struct GitHubCommentPostResult: Equatable, Sendable {
    public var url: URL?
    public var summary: String

    public init(url: URL? = nil, summary: String) {
        self.url = url
        self.summary = summary
    }
}

public enum DraftCommentError: Error, Equatable, Sendable {
    case noActivePlanningArtifact
    case noPreparedDraftComment
    case staleDraftComment
    case duplicateDecision
    case emptyCommentBody
    case githubPostFailed(String)

    var apiErrorCode: String {
        switch self {
        case .noActivePlanningArtifact:
            return "active_planning_artifact_required"
        case .noPreparedDraftComment:
            return "draft_comment_required"
        case .staleDraftComment:
            return "draft_comment_stale"
        case .duplicateDecision:
            return "draft_comment_decision_duplicate"
        case .emptyCommentBody:
            return "draft_comment_body_required"
        case .githubPostFailed:
            return "github_comment_post_failed"
        }
    }

    var userMessage: String {
        switch self {
        case .noActivePlanningArtifact:
            return "Attach a Planning Artifact before preparing a Draft Comment."
        case .noPreparedDraftComment:
            return "Prepare a Draft Comment before approving or rejecting it."
        case .staleDraftComment:
            return "That Draft Comment is no longer pending approval."
        case .duplicateDecision:
            return "That Draft Comment was already decided."
        case .emptyCommentBody:
            return "A Draft Comment cannot be posted with an empty body."
        case .githubPostFailed(let detail):
            return detail.isEmpty ? "The GitHub comment could not be posted through local gh authentication." : detail
        }
    }
}

public struct GitHubCLICommentPoster: GitHubCommentPosting {
    private let executor: any ProcessCommandExecuting

    public init(executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor()) {
        self.executor = executor
    }

    public func postGeneralComment(_ body: String, to artifact: PlanningArtifact) throws -> GitHubCommentPostResult {
        let artifactCommand = artifact.kind == .issue ? "issue" : "pr"
        var arguments = [
            artifactCommand,
            "comment",
            "\(artifact.number)",
            "--body",
            body
        ]
        if let repoSlug = repoSlug(from: artifact.url) {
            arguments.append(contentsOf: ["--repo", repoSlug])
        }

        do {
            let result = try executor.run(executable: "gh", arguments: arguments)
            let output = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return GitHubCommentPostResult(
                url: output.isEmpty ? nil : URL(string: output),
                summary: output.isEmpty ? "Comment posted to GitHub." : output
            )
        } catch let error as ProcessCommandFailure {
            throw DraftCommentError.githubPostFailed(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as DraftCommentError {
            throw error
        } catch {
            throw DraftCommentError.githubPostFailed(String(describing: error))
        }
    }

    private func repoSlug(from url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else {
            return nil
        }
        return "\(components[0])/\(components[1])"
    }
}

struct ObservableDraftCommentBuilder: Sendable {
    func build(
        draftID: String,
        artifact: PlanningArtifact,
        activeSession: AttachedSession?,
        pendingInput: PendingInputState,
        pendingApprovalRequest: ApprovalRequestState?,
        fileReview: FileReviewState,
        auditEvents: [SessionEventLogEntry],
        preparedAt: Date
    ) -> DraftCommentState {
        var lines: [String] = []
        lines.append("## Observable Summary")
        lines.append("")
        lines.append("- Planning Artifact: \(artifact.kind == .issue ? "Issue" : "PR") #\(artifact.number) - \(artifact.title)")
        lines.append("- State: \(artifact.state.capitalized)")
        if let activeSession {
            lines.append("- Agent Session: \(activeSession.session.displayName) (\(activeSession.session.state.rawValue))")
            lines.append("- Session Summary: \(activeSession.session.summary)")
        } else {
            lines.append("- Agent Session: none attached")
        }

        lines.append("")
        lines.append("### Observable Events")
        if auditEvents.isEmpty {
            lines.append("- No stored session events yet.")
        } else {
            for event in auditEvents.suffix(8) {
                lines.append("- \(event.title): \(oneLine(event.detail, limit: 160))")
            }
        }

        lines.append("")
        lines.append("### Requested Decisions")
        if let pendingApprovalRequest {
            lines.append("- Pending approval: \(pendingApprovalRequest.title) - \(oneLine(pendingApprovalRequest.detail, limit: 160))")
        } else {
            lines.append("- No pending approval request.")
        }
        if pendingInput.status != .unavailable {
            lines.append("- Pending input: \(pendingInput.prompt.map { oneLine($0, limit: 160) } ?? pendingInput.status.rawValue)")
        }

        lines.append("")
        lines.append("### File Review")
        lines.append("- \(fileReview.summary)")
        for file in fileReview.files.prefix(8) {
            let risk = file.riskSignals.isEmpty ? "" : " Risks: \(file.riskSignals.joined(separator: ", "))."
            lines.append("- \(file.path): \(file.summary) \(file.ownership.rawValue).\(risk)")
        }

        lines.append("")
        lines.append("_Prepared from Mac-observable prompts, session events, structured decisions, command outcomes, and File Review data. Posting requires explicit Owner Device approval._")

        return DraftCommentState(
            id: draftID,
            status: .prepared,
            title: "Draft GitHub comment for \(artifact.kind == .issue ? "Issue" : "PR") #\(artifact.number)",
            body: lines.joined(separator: "\n"),
            preparedAt: preparedAt,
            requiresApproval: true
        )
    }

    private func oneLine(_ value: String, limit: Int) -> String {
        let collapsed = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else {
            return collapsed
        }
        return "\(collapsed.prefix(limit))..."
    }
}
