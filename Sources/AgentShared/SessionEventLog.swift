import Foundation

public enum SessionEventType: String, Codable, Equatable, CaseIterable, Sendable {
    case planningArtifactAttached
    case sessionLifecycle
    case structuredActionAttempt
    case structuredActionResult
}

public struct SessionEventLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var planningArtifactID: PlanningArtifact.ID
    public var agentSessionID: AgentSession.ID?
    public var eventType: SessionEventType
    public var title: String
    public var detail: String
    public var occurredAt: Date
    public var metadata: [String: String]

    public init(
        id: String,
        planningArtifactID: PlanningArtifact.ID,
        agentSessionID: AgentSession.ID? = nil,
        eventType: SessionEventType,
        title: String,
        detail: String,
        occurredAt: Date,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.planningArtifactID = planningArtifactID
        self.agentSessionID = agentSessionID
        self.eventType = eventType
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
        self.metadata = metadata
    }
}
