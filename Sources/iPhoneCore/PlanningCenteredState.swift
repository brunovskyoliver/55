import AgentShared
import Foundation

public struct PlanningCenteredState: Equatable, Sendable {
    public var configuredRepositoryPath: String?
    public var activePlanningArtifact: PlanningArtifactSummary
    public var attachedSession: AttachedSessionSummary?
    public var structuredActions: [StructuredActionSummary]
    public var fileReview: PlaceholderSummary
    public var auditTimeline: AuditTimelineSummary

    public init(
        configuredRepositoryPath: String? = nil,
        activePlanningArtifact: PlanningArtifactSummary,
        attachedSession: AttachedSessionSummary?,
        structuredActions: [StructuredActionSummary],
        fileReview: PlaceholderSummary,
        auditTimeline: AuditTimelineSummary
    ) {
        self.configuredRepositoryPath = configuredRepositoryPath
        self.activePlanningArtifact = activePlanningArtifact
        self.attachedSession = attachedSession
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

    public init(id: String, title: String, isAvailable: Bool, reason: String) {
        self.id = id
        self.title = title
        self.isAvailable = isAvailable
        self.reason = reason
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
            structuredActions: actionSummaries(response.structuredActionAvailability),
            fileReview: PlaceholderSummary(
                title: "File Review",
                detail: "\(response.fileReview.summary) Changed files: \(response.fileReview.changedFileCount)."
            ),
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
        StructuredActionSummary(id: id, title: title, isAvailable: state.isAvailable, reason: state.reason)
    }
}

public enum PlanningStateMapperError: Error, Equatable {
    case missingActivePlanningArtifact
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
        case .stopped:
            return "Stopped"
        }
    }
}
