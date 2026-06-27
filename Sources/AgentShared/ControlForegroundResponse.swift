import Foundation

public struct ControlForegroundResponse: Codable, Equatable, Sendable {
    public var planningArtifacts: [PlanningArtifact]
    public var activePlanningArtifactID: PlanningArtifact.ID?
    public var attachedSessions: [AttachedSession]
    public var structuredActionAvailability: StructuredActionAvailability
    public var fileReview: FileReviewPlaceholder
    public var auditTimeline: AuditTimelinePlaceholder

    public init(
        planningArtifacts: [PlanningArtifact],
        activePlanningArtifactID: PlanningArtifact.ID?,
        attachedSessions: [AttachedSession],
        structuredActionAvailability: StructuredActionAvailability,
        fileReview: FileReviewPlaceholder,
        auditTimeline: AuditTimelinePlaceholder
    ) {
        self.planningArtifacts = planningArtifacts
        self.activePlanningArtifactID = activePlanningArtifactID
        self.attachedSessions = attachedSessions
        self.structuredActionAvailability = structuredActionAvailability
        self.fileReview = fileReview
        self.auditTimeline = auditTimeline
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
        case stopped
    }

    public var id: String
    public var displayName: String
    public var state: State
    public var summary: String

    public init(id: String, displayName: String, state: State, summary: String) {
        self.id = id
        self.displayName = displayName
        self.state = state
        self.summary = summary
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

    public init(isAvailable: Bool, reason: String) {
        self.isAvailable = isAvailable
        self.reason = reason
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
