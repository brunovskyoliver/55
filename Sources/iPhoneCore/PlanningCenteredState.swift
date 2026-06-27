import AgentShared
import Foundation

public struct PlanningCenteredState: Equatable, Sendable {
    public var configuredRepositoryPath: String?
    public var activePlanningArtifact: PlanningArtifactSummary
    public var attachedSession: AttachedSessionSummary?
    public var pendingApprovalRequest: ApprovalRequestSummary?
    public var structuredActions: [StructuredActionSummary]
    public var fileReview: FileReviewSummary
    public var auditTimeline: AuditTimelineSummary

    public init(
        configuredRepositoryPath: String? = nil,
        activePlanningArtifact: PlanningArtifactSummary,
        attachedSession: AttachedSessionSummary?,
        pendingApprovalRequest: ApprovalRequestSummary? = nil,
        structuredActions: [StructuredActionSummary],
        fileReview: FileReviewSummary,
        auditTimeline: AuditTimelineSummary
    ) {
        self.configuredRepositoryPath = configuredRepositoryPath
        self.activePlanningArtifact = activePlanningArtifact
        self.attachedSession = attachedSession
        self.pendingApprovalRequest = pendingApprovalRequest
        self.structuredActions = structuredActions
        self.fileReview = fileReview
        self.auditTimeline = auditTimeline
    }
}

public struct PlanningArtifactSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var affordanceTitle: String
    public var title: String
    public var state: String
    public var url: URL

    public init(id: String, label: String, affordanceTitle: String, title: String, state: String, url: URL) {
        self.id = id
        self.label = label
        self.affordanceTitle = affordanceTitle
        self.title = title
        self.state = state
        self.url = url
    }
}

public struct AttachedSessionSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var stateText: String
    public var summary: String
    public var tmuxAttachCommand: String?
    public var baselineSummary: String?
    public var baselineIsDirty: Bool

    public init(
        id: String,
        title: String,
        stateText: String,
        summary: String,
        tmuxAttachCommand: String? = nil,
        baselineSummary: String? = nil,
        baselineIsDirty: Bool = false
    ) {
        self.id = id
        self.title = title
        self.stateText = stateText
        self.summary = summary
        self.tmuxAttachCommand = tmuxAttachCommand
        self.baselineSummary = baselineSummary
        self.baselineIsDirty = baselineIsDirty
    }
}

public struct StructuredActionSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var isAvailable: Bool
    public var reason: String
    public var requiresConfirmation: Bool

    public init(
        id: String,
        title: String,
        isAvailable: Bool,
        reason: String,
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.title = title
        self.isAvailable = isAvailable
        self.reason = reason
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct ApprovalRequestSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var requestedAt: Date

    public init(id: String, title: String, detail: String, requestedAt: Date) {
        self.id = id
        self.title = title
        self.detail = detail
        self.requestedAt = requestedAt
    }
}

public struct PlaceholderSummary: Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public struct FileReviewSummary: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var changedFileCount: Int
    public var preExistingChangeCount: Int
    public var agentSessionChangeCount: Int
    public var files: [FileReviewFileSummary]

    public init(
        title: String,
        detail: String,
        changedFileCount: Int,
        preExistingChangeCount: Int,
        agentSessionChangeCount: Int,
        files: [FileReviewFileSummary]
    ) {
        self.title = title
        self.detail = detail
        self.changedFileCount = changedFileCount
        self.preExistingChangeCount = preExistingChangeCount
        self.agentSessionChangeCount = agentSessionChangeCount
        self.files = files
    }
}

public struct FileReviewFileSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var previousPath: String?
    public var ownershipTitle: String
    public var changeKindTitle: String
    public var changeSize: String
    public var summary: String
    public var riskSignals: [String]
    public var selectedHunks: [FileReviewHunkSummary]

    public init(
        id: String,
        path: String,
        previousPath: String?,
        ownershipTitle: String,
        changeKindTitle: String,
        changeSize: String,
        summary: String,
        riskSignals: [String],
        selectedHunks: [FileReviewHunkSummary]
    ) {
        self.id = id
        self.path = path
        self.previousPath = previousPath
        self.ownershipTitle = ownershipTitle
        self.changeKindTitle = changeKindTitle
        self.changeSize = changeSize
        self.summary = summary
        self.riskSignals = riskSignals
        self.selectedHunks = selectedHunks
    }
}

public struct FileReviewHunkSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var header: String
    public var lines: [String]

    public init(id: String, header: String, lines: [String]) {
        self.id = id
        self.header = header
        self.lines = lines
    }
}

public struct AuditTimelineSummary: Equatable, Sendable {
    public var title: String
    public var entries: [AuditTimelineItemSummary]

    public init(title: String, entries: [AuditTimelineItemSummary]) {
        self.title = title
        self.entries = entries
    }
}

public struct AuditTimelineItemSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var occurredAt: Date

    public init(id: String, title: String, detail: String, occurredAt: Date) {
        self.id = id
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

public protocol PlanningStateMapping: Sendable {
    func map(_ response: ControlForegroundResponse) throws -> PlanningCenteredState
}

public struct PlanningStateMapper: PlanningStateMapping {
    public init() {}

    public func map(_ response: ControlForegroundResponse) throws -> PlanningCenteredState {
        guard let activeArtifact = activeArtifact(in: response) else {
            throw PlanningStateMapperError.missingActivePlanningArtifact
        }

        let attachedSession = response.attachedSessions
            .first { $0.planningArtifactID == activeArtifact.id }
            .map(sessionSummary)

        return PlanningCenteredState(
            configuredRepositoryPath: response.configuredRepository?.path,
            activePlanningArtifact: artifactSummary(activeArtifact),
            attachedSession: attachedSession,
            pendingApprovalRequest: response.pendingApprovalRequest.map(approvalRequestSummary),
            structuredActions: actionSummaries(response.structuredActionAvailability),
            fileReview: fileReviewSummary(response.fileReview),
            auditTimeline: AuditTimelineSummary(
                title: response.auditTimeline.summary,
                entries: response.auditTimeline.entries.map {
                    AuditTimelineItemSummary(
                        id: $0.id,
                        title: $0.title,
                        detail: $0.detail,
                        occurredAt: $0.occurredAt
                    )
                }
            )
        )
    }

    private func activeArtifact(in response: ControlForegroundResponse) -> PlanningArtifact? {
        if let activeID = response.activePlanningArtifactID {
            return response.planningArtifacts.first { $0.id == activeID }
        }

        return response.planningArtifacts.first
    }

    private func artifactSummary(_ artifact: PlanningArtifact) -> PlanningArtifactSummary {
        PlanningArtifactSummary(
            id: artifact.id,
            label: artifact.kind == .issue ? "Issue #\(artifact.number)" : "PR #\(artifact.number)",
            affordanceTitle: artifact.kind == .issue ? "Issue Planning" : "PR Review",
            title: artifact.title,
            state: artifact.state.capitalized,
            url: artifact.url
        )
    }

    private func sessionSummary(_ attachment: AttachedSession) -> AttachedSessionSummary {
        AttachedSessionSummary(
            id: attachment.session.id,
            title: attachment.session.displayName,
            stateText: attachment.session.state.displayText,
            summary: attachment.session.summary,
            tmuxAttachCommand: attachment.session.tmuxAttachment?.attachCommand,
            baselineSummary: attachment.session.worktreeBaseline?.summary,
            baselineIsDirty: attachment.session.worktreeBaseline?.isDirty ?? false
        )
    }

    private func actionSummaries(_ availability: StructuredActionAvailability) -> [StructuredActionSummary] {
        [
            actionSummary(id: "reply", title: "Reply", state: availability.reply),
            actionSummary(id: "approve", title: "Approve", state: availability.approve),
            actionSummary(id: "deny", title: "Deny", state: availability.deny),
            actionSummary(id: "draft-comment", title: "Draft Comment", state: availability.draftComment),
            actionSummary(id: "guarded-stop", title: "Guarded Stop", state: availability.guardedStop)
        ]
    }

    private func actionSummary(id: String, title: String, state: StructuredActionState) -> StructuredActionSummary {
        StructuredActionSummary(
            id: id,
            title: title,
            isAvailable: state.isAvailable,
            reason: state.reason,
            requiresConfirmation: state.requiresConfirmation
        )
    }

    private func approvalRequestSummary(_ request: ApprovalRequestState) -> ApprovalRequestSummary {
        ApprovalRequestSummary(
            id: request.requestID,
            title: request.title,
            detail: request.detail,
            requestedAt: request.requestedAt
        )
    }

    private func fileReviewSummary(_ fileReview: FileReviewState) -> FileReviewSummary {
        FileReviewSummary(
            title: "File Review",
            detail: "\(fileReview.summary) Changed files: \(fileReview.changedFileCount).",
            changedFileCount: fileReview.changedFileCount,
            preExistingChangeCount: fileReview.preExistingChangeCount,
            agentSessionChangeCount: fileReview.agentSessionChangeCount,
            files: fileReview.files.map(fileReviewFileSummary)
        )
    }

    private func fileReviewFileSummary(_ file: FileReviewFile) -> FileReviewFileSummary {
        FileReviewFileSummary(
            id: file.id,
            path: file.path,
            previousPath: file.previousPath,
            ownershipTitle: file.ownership.displayTitle,
            changeKindTitle: file.changeKind.displayTitle,
            changeSize: "+\(file.additions) / -\(file.deletions)",
            summary: file.summary,
            riskSignals: file.riskSignals,
            selectedHunks: file.selectedHunks.map {
                FileReviewHunkSummary(id: $0.id, header: $0.header, lines: $0.lines)
            }
        )
    }
}

public enum PlanningStateMapperError: Error, Equatable {
    case missingActivePlanningArtifact
}

private extension FileReviewFile.Ownership {
    var displayTitle: String {
        switch self {
        case .preExistingDirtyWorktree:
            return "Pre-existing"
        case .agentSession:
            return "Agent Session"
        }
    }
}

private extension FileReviewFile.ChangeKind {
    var displayTitle: String {
        switch self {
        case .added:
            return "Added"
        case .modified:
            return "Modified"
        case .deleted:
            return "Deleted"
        case .renamed:
            return "Renamed"
        case .untracked:
            return "Untracked"
        case .copied:
            return "Copied"
        case .typeChanged:
            return "Type Changed"
        case .unknown:
            return "Changed"
        }
    }
}

private extension AgentSession.State {
    var displayText: String {
        switch self {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .waitingForInput:
            return "Waiting for Input"
        case .waitingForApproval:
            return "Waiting for Approval"
        case .stopped:
            return "Stopped"
        }
    }
}
