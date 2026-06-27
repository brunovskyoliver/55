import AgentShared
import Foundation

public struct PlanningCenteredState: Equatable, Sendable {
    public var activePlanningArtifact: PlanningArtifactSummary
    public var attachedSession: AttachedSessionSummary?
    public var structuredActions: [StructuredActionSummary]
    public var fileReview: PlaceholderSummary
    public var auditTimeline: PlaceholderSummary

    public init(
        activePlanningArtifact: PlanningArtifactSummary,
        attachedSession: AttachedSessionSummary?,
        structuredActions: [StructuredActionSummary],
        fileReview: PlaceholderSummary,
        auditTimeline: PlaceholderSummary
    ) {
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
    public var title: String
    public var state: String
    public var url: URL

    public init(id: String, label: String, title: String, state: String, url: URL) {
        self.id = id
        self.label = label
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

    public init(id: String, title: String, stateText: String, summary: String) {
        self.id = id
        self.title = title
        self.stateText = stateText
        self.summary = summary
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
            activePlanningArtifact: artifactSummary(activeArtifact),
            attachedSession: attachedSession,
            structuredActions: actionSummaries(response.structuredActionAvailability),
            fileReview: PlaceholderSummary(
                title: "File Review",
                detail: "\(response.fileReview.summary) Changed files: \(response.fileReview.changedFileCount)."
            ),
            auditTimeline: PlaceholderSummary(
                title: response.auditTimeline.summary,
                detail: response.auditTimeline.entries.first?.detail ?? "No audit events yet."
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
            summary: attachment.session.summary
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
