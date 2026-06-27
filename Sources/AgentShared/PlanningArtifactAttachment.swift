import Foundation

public struct AttachPlanningArtifactRequest: Codable, Equatable, Sendable {
    public var kind: PlanningArtifact.Kind
    public var reference: String

    public init(kind: PlanningArtifact.Kind, reference: String) {
        self.kind = kind
        self.reference = reference
    }
}

public struct AttachPlanningArtifactResponse: Codable, Equatable, Sendable {
    public var planningArtifact: PlanningArtifact
    public var foregroundState: ControlForegroundResponse

    public init(planningArtifact: PlanningArtifact, foregroundState: ControlForegroundResponse) {
        self.planningArtifact = planningArtifact
        self.foregroundState = foregroundState
    }
}

public struct ControlAPIErrorResponse: Codable, Equatable, Sendable {
    public var error: String
    public var message: String

    public init(error: String, message: String) {
        self.error = error
        self.message = message
    }
}
