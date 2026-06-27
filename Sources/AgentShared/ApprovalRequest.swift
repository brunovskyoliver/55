import Foundation

public enum ApprovalRequestSource: String, Codable, Equatable, Sendable {
    case claudeCodeHook
}

public enum ApprovalRequestDecision: String, Codable, Equatable, Sendable {
    case approve
    case deny
}

public struct ApprovalRequestState: Codable, Equatable, Sendable {
    public var requestID: String
    public var source: ApprovalRequestSource
    public var title: String
    public var detail: String
    public var requestedAt: Date

    public init(
        requestID: String,
        source: ApprovalRequestSource,
        title: String,
        detail: String,
        requestedAt: Date
    ) {
        self.requestID = requestID
        self.source = source
        self.title = title
        self.detail = detail
        self.requestedAt = requestedAt
    }
}

public struct ApprovalRequestSignal: Codable, Equatable, Sendable {
    public var requestID: String
    public var source: ApprovalRequestSource
    public var title: String
    public var detail: String

    public init(
        requestID: String,
        source: ApprovalRequestSource,
        title: String,
        detail: String
    ) {
        self.requestID = requestID
        self.source = source
        self.title = title
        self.detail = detail
    }

    public static func claudeCodeHook(
        requestID: String,
        title: String,
        detail: String
    ) -> ApprovalRequestSignal {
        ApprovalRequestSignal(
            requestID: requestID,
            source: .claudeCodeHook,
            title: title,
            detail: detail
        )
    }
}

public struct SubmitApprovalDecisionRequest: Codable, Equatable, Sendable {
    public var requestID: String
    public var decision: ApprovalRequestDecision

    public init(requestID: String, decision: ApprovalRequestDecision) {
        self.requestID = requestID
        self.decision = decision
    }
}

public struct SubmitApprovalDecisionResponse: Codable, Equatable, Sendable {
    public var foregroundState: ControlForegroundResponse

    public init(foregroundState: ControlForegroundResponse) {
        self.foregroundState = foregroundState
    }
}
