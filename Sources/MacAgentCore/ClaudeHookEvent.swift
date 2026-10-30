import Foundation

// MARK: - Hook payload (received from Claude Code via stdin)

/// The raw JSON payload Claude Code sends to a hook command via stdin.
public struct ClaudeHookPayload: Decodable, Sendable {
    public var sessionId: String
    public var transcriptPath: String?
    public var cwd: String?
    public var permissionMode: String?
    public var hookEventName: String
    /// Present for PreToolUse and PostToolUse.
    public var toolName: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
    }
}

// MARK: - Enriched event

/// A hook event enriched with Mac Agent metadata (wrappedSessionID, raw body, receive time).
public struct ClaudeHookEvent: Sendable {
    public var wrappedSessionID: String
    public var payload: ClaudeHookPayload
    /// Raw JSON body as received — used for tool_input display and forwarding.
    public var rawBody: Data
    public var receivedAt: Date

    public var kind: ClaudeHookEventKind {
        ClaudeHookEventKind(rawValue: payload.hookEventName) ?? .unknown
    }

    public init(
        wrappedSessionID: String,
        payload: ClaudeHookPayload,
        rawBody: Data,
        receivedAt: Date = Date()
    ) {
        self.wrappedSessionID = wrappedSessionID
        self.payload = payload
        self.rawBody = rawBody
        self.receivedAt = receivedAt
    }
}

// MARK: - Event kind

public enum ClaudeHookEventKind: String, Sendable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case subagentStop = "SubagentStop"
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case preCompact = "PreCompact"
    case notification = "Notification"
    case unknown
}
