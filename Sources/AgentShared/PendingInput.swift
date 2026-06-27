import Foundation

public enum PendingInputStatus: String, Codable, Equatable, Sendable {
    case unavailable
    case hookConfirmed
    case uncertain
}

public enum PendingInputSource: String, Codable, Equatable, Sendable {
    case claudeCodeHook
    case tmuxHeuristic
}

public struct PendingInputState: Codable, Equatable, Sendable {
    public var status: PendingInputStatus
    public var source: PendingInputSource?
    public var prompt: String?
    public var detectedAt: Date?

    public init(
        status: PendingInputStatus,
        source: PendingInputSource? = nil,
        prompt: String? = nil,
        detectedAt: Date? = nil
    ) {
        self.status = status
        self.source = source
        self.prompt = prompt
        self.detectedAt = detectedAt
    }

    public static let unavailable = PendingInputState(status: .unavailable)

    public var requiresExtraConfirmation: Bool {
        status == .uncertain
    }
}

public enum PendingInputSignalKind: String, Codable, Equatable, Sendable {
    case detected
    case cleared
}

public struct PendingInputSignal: Codable, Equatable, Sendable {
    public var source: PendingInputSource
    public var kind: PendingInputSignalKind
    public var prompt: String?

    public init(source: PendingInputSource, kind: PendingInputSignalKind, prompt: String? = nil) {
        self.source = source
        self.kind = kind
        self.prompt = prompt
    }

    public static func hookConfirmed(prompt: String? = nil) -> PendingInputSignal {
        PendingInputSignal(source: .claudeCodeHook, kind: .detected, prompt: prompt)
    }

    public static func tmuxHeuristic(prompt: String? = nil) -> PendingInputSignal {
        PendingInputSignal(source: .tmuxHeuristic, kind: .detected, prompt: prompt)
    }

    public static func tmuxHeuristicCleared() -> PendingInputSignal {
        PendingInputSignal(source: .tmuxHeuristic, kind: .cleared)
    }
}

public struct SubmitPendingInputReplyRequest: Codable, Equatable, Sendable {
    public var reply: String
    public var confirmUncertainInput: Bool

    public init(reply: String, confirmUncertainInput: Bool = false) {
        self.reply = reply
        self.confirmUncertainInput = confirmUncertainInput
    }
}

public struct SubmitPendingInputReplyResponse: Codable, Equatable, Sendable {
    public var foregroundState: ControlForegroundResponse

    public init(foregroundState: ControlForegroundResponse) {
        self.foregroundState = foregroundState
    }
}
