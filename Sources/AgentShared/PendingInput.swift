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

/// A single selectable option surfaced when Claude presents a multiple-choice question
/// (e.g. via `AskUserQuestion`).
public struct PendingInputOption: Codable, Equatable, Identifiable, Sendable {
    /// Stable index-based identifier for the option within this detection (e.g. "0", "1", …).
    public var id: String
    /// Human-readable label, as presented by Claude Code.
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct PendingInputState: Codable, Equatable, Sendable {
    public var status: PendingInputStatus
    public var source: PendingInputSource?
    public var prompt: String?
    public var detectedAt: Date?
    /// Stable identifier for the current detection. Used for stale-reply detection.
    /// `nil` when `status == .unavailable`.
    public var requestID: String?
    /// Selectable options if Claude is asking a multiple-choice question.
    /// Empty when not a question or when options could not be extracted.
    public var options: [PendingInputOption]

    public init(
        status: PendingInputStatus,
        source: PendingInputSource? = nil,
        prompt: String? = nil,
        detectedAt: Date? = nil,
        requestID: String? = nil,
        options: [PendingInputOption] = []
    ) {
        self.status = status
        self.source = source
        self.prompt = prompt
        self.detectedAt = detectedAt
        self.requestID = requestID
        self.options = options
    }

    // Custom decoder for backward compatibility: `requestID` and `options` were added after
    // initial deployment; older JSON may omit them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(PendingInputStatus.self, forKey: .status)
        source = try c.decodeIfPresent(PendingInputSource.self, forKey: .source)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        detectedAt = try c.decodeIfPresent(Date.self, forKey: .detectedAt)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        options = try c.decodeIfPresent([PendingInputOption].self, forKey: .options) ?? []
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
    /// Stable per-detection identifier emitted by the adapter. Carried into `PendingInputState`.
    public var requestID: String?
    /// Selectable options for question-type pending input.
    public var options: [PendingInputOption]

    public init(
        source: PendingInputSource,
        kind: PendingInputSignalKind,
        prompt: String? = nil,
        requestID: String? = nil,
        options: [PendingInputOption] = []
    ) {
        self.source = source
        self.kind = kind
        self.prompt = prompt
        self.requestID = requestID
        self.options = options
    }

    public static func hookConfirmed(prompt: String? = nil) -> PendingInputSignal {
        PendingInputSignal(source: .claudeCodeHook, kind: .detected, prompt: prompt)
    }

    public static func hookCleared() -> PendingInputSignal {
        PendingInputSignal(source: .claudeCodeHook, kind: .cleared)
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
    /// When set, the server verifies this matches the current `PendingInputState.requestID`
    /// before accepting the reply, preventing stale replies after state has changed.
    public var requestID: String?

    public init(reply: String, confirmUncertainInput: Bool = false, requestID: String? = nil) {
        self.reply = reply
        self.confirmUncertainInput = confirmUncertainInput
        self.requestID = requestID
    }
}

public struct SubmitPendingInputReplyResponse: Codable, Equatable, Sendable {
    public var foregroundState: ControlForegroundResponse

    public init(foregroundState: ControlForegroundResponse) {
        self.foregroundState = foregroundState
    }
}
