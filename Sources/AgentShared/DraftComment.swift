import Foundation

public struct DraftCommentState: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case unavailable
        case prepared
        case posted
        case rejected
        case failed
    }

    public var id: String
    public var status: Status
    public var title: String
    public var body: String
    public var preparedAt: Date?
    public var requiresApproval: Bool
    public var failureMessage: String?

    public init(
        id: String,
        status: Status,
        title: String,
        body: String,
        preparedAt: Date? = nil,
        requiresApproval: Bool = true,
        failureMessage: String? = nil
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.body = body
        self.preparedAt = preparedAt
        self.requiresApproval = requiresApproval
        self.failureMessage = failureMessage
    }

    public static let unavailable = DraftCommentState(
        id: "draft-comment-unavailable",
        status: .unavailable,
        title: "Draft Comment unavailable",
        body: "",
        preparedAt: nil,
        requiresApproval: false
    )
}

public enum DraftCommentDecision: String, Codable, Equatable, Sendable {
    case approve
    case reject
}

public struct PrepareDraftCommentRequest: Codable, Equatable, Sendable {
    public var forceRegenerate: Bool

    public init(forceRegenerate: Bool = false) {
        self.forceRegenerate = forceRegenerate
    }

    private enum CodingKeys: String, CodingKey {
        case forceRegenerate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        forceRegenerate = try container.decodeIfPresent(Bool.self, forKey: .forceRegenerate) ?? false
    }
}

public struct PrepareDraftCommentResponse: Codable, Equatable, Sendable {
    public var draftComment: DraftCommentState
    public var foregroundState: ControlForegroundResponse

    public init(draftComment: DraftCommentState, foregroundState: ControlForegroundResponse) {
        self.draftComment = draftComment
        self.foregroundState = foregroundState
    }
}

public struct SubmitDraftCommentDecisionRequest: Codable, Equatable, Sendable {
    public var draftID: String
    public var decision: DraftCommentDecision
    public var approvedBody: String?

    public init(draftID: String, decision: DraftCommentDecision, approvedBody: String? = nil) {
        self.draftID = draftID
        self.decision = decision
        self.approvedBody = approvedBody
    }
}

public struct SubmitDraftCommentDecisionResponse: Codable, Equatable, Sendable {
    public var foregroundState: ControlForegroundResponse

    public init(foregroundState: ControlForegroundResponse) {
        self.foregroundState = foregroundState
    }
}
