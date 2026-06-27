import Foundation

public struct ControlForegroundResponse: Codable, Equatable, Sendable {
    public var configuredRepository: ConfiguredRepository?
    public var planningArtifacts: [PlanningArtifact]
    public var activePlanningArtifactID: PlanningArtifact.ID?
    public var attachedSessions: [AttachedSession]
    public var pendingInput: PendingInputState
    public var pendingApprovalRequest: ApprovalRequestState?
    public var structuredActionAvailability: StructuredActionAvailability
    public var fileReview: FileReviewPlaceholder
    public var auditTimeline: AuditTimelinePlaceholder

    public init(
        configuredRepository: ConfiguredRepository? = nil,
        planningArtifacts: [PlanningArtifact],
        activePlanningArtifactID: PlanningArtifact.ID?,
        attachedSessions: [AttachedSession],
        pendingInput: PendingInputState = .unavailable,
        pendingApprovalRequest: ApprovalRequestState? = nil,
        structuredActionAvailability: StructuredActionAvailability,
        fileReview: FileReviewPlaceholder,
        auditTimeline: AuditTimelinePlaceholder
    ) {
        self.configuredRepository = configuredRepository
        self.planningArtifacts = planningArtifacts
        self.activePlanningArtifactID = activePlanningArtifactID
        self.attachedSessions = attachedSessions
        self.pendingInput = pendingInput
        self.pendingApprovalRequest = pendingApprovalRequest
        self.structuredActionAvailability = structuredActionAvailability
        self.fileReview = fileReview
        self.auditTimeline = auditTimeline
    }
}

public struct ConfiguredRepository: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String

    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}

public struct PlanningArtifact: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Equatable, CaseIterable, Sendable {
        case issue
        case pullRequest
    }

    public var id: String
    public var kind: Kind
    public var number: Int
    public var title: String
    public var url: URL
    public var state: String

    public init(id: String, kind: Kind, number: Int, title: String, url: URL, state: String) {
        self.id = id
        self.kind = kind
        self.number = number
        self.title = title
        self.url = url
        self.state = state
    }
}

public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case idle
        case running
        case waitingForInput
        case waitingForApproval
        case stopped
    }

    public var id: String
    public var displayName: String
    public var state: State
    public var summary: String
    public var tmuxAttachment: TmuxAttachmentInfo?
    public var worktreeBaseline: WorktreeBaselineSummary?

    public init(
        id: String,
        displayName: String,
        state: State,
        summary: String,
        tmuxAttachment: TmuxAttachmentInfo? = nil,
        worktreeBaseline: WorktreeBaselineSummary? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.state = state
        self.summary = summary
        self.tmuxAttachment = tmuxAttachment
        self.worktreeBaseline = worktreeBaseline
    }
}

public struct AttachedSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(planningArtifactID):\(session.id)" }
    public var planningArtifactID: PlanningArtifact.ID
    public var session: AgentSession

    public init(planningArtifactID: PlanningArtifact.ID, session: AgentSession) {
        self.planningArtifactID = planningArtifactID
        self.session = session
    }
}

public struct WorktreeBaselineSummary: Codable, Equatable, Sendable {
    public var repositoryPath: String
    public var branchName: String
    public var headSHA: String?
    public var isDirty: Bool
    public var changedFileCount: Int
    public var summary: String
    public var capturedAt: Date

    public init(
        repositoryPath: String,
        branchName: String,
        headSHA: String?,
        isDirty: Bool,
        changedFileCount: Int,
        summary: String,
        capturedAt: Date
    ) {
        self.repositoryPath = repositoryPath
        self.branchName = branchName
        self.headSHA = headSHA
        self.isDirty = isDirty
        self.changedFileCount = changedFileCount
        self.summary = summary
        self.capturedAt = capturedAt
    }
}

public struct TmuxAttachmentInfo: Codable, Equatable, Sendable {
    public var sessionName: String
    public var windowName: String
    public var attachCommand: String

    public init(sessionName: String, windowName: String, attachCommand: String) {
        self.sessionName = sessionName
        self.windowName = windowName
        self.attachCommand = attachCommand
    }
}

public struct StructuredActionAvailability: Codable, Equatable, Sendable {
    public var reply: StructuredActionState
    public var approve: StructuredActionState
    public var deny: StructuredActionState
    public var draftComment: StructuredActionState
    public var guardedStop: StructuredActionState

    public init(
        reply: StructuredActionState,
        approve: StructuredActionState,
        deny: StructuredActionState,
        draftComment: StructuredActionState,
        guardedStop: StructuredActionState
    ) {
        self.reply = reply
        self.approve = approve
        self.deny = deny
        self.draftComment = draftComment
        self.guardedStop = guardedStop
    }
}

public struct StructuredActionState: Codable, Equatable, Sendable {
    public var isAvailable: Bool
    public var reason: String
    public var requiresConfirmation: Bool

    public init(isAvailable: Bool, reason: String, requiresConfirmation: Bool = false) {
        self.isAvailable = isAvailable
        self.reason = reason
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct FileReviewPlaceholder: Codable, Equatable, Sendable {
    public var status: String
    public var summary: String
    public var changedFileCount: Int

    public init(status: String, summary: String, changedFileCount: Int) {
        self.status = status
        self.summary = summary
        self.changedFileCount = changedFileCount
    }
}

public struct AuditTimelinePlaceholder: Codable, Equatable, Sendable {
    public var summary: String
    public var entries: [AuditTimelineEntry]

    public init(summary: String, entries: [AuditTimelineEntry]) {
        self.summary = summary
        self.entries = entries
    }
}

public struct AuditTimelineEntry: Codable, Equatable, Identifiable, Sendable {
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
