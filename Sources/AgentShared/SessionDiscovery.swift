import Foundation

// MARK: - Discoverable session

/// A Claude Code session visible on this Mac, regardless of whether it was launched
/// by the Mac Agent or started externally by the user.
public struct DiscoverableSession: Codable, Equatable, Identifiable, Sendable {
    /// Stable identifier — `AGENT_WRAPPED_SESSION_ID` for agent-launched sessions,
    /// a synthetic key (e.g. "tmux:<name>") for external sessions.
    public var id: String
    public var kind: Kind
    /// tmux session name when the process is inside a managed tmux session.
    public var tmuxSessionName: String?
    /// tmux window name (e.g. "claude") when known.
    public var tmuxWindowName: String?
    /// tmux pane id (e.g. "%3") when known — stable across respawn-pane, used for precise targeting.
    public var tmuxPaneID: String?
    /// Working directory / repository path; may be empty when unknown.
    public var repoPath: String
    /// Last pane activity timestamp from tmux (or process start for bare sessions).
    public var lastActivity: Date
    /// Whether this session already has hook wiring (full phone control available).
    public var hookWired: Bool

    public enum Kind: String, Codable, Equatable, Sendable {
        /// Started by this Mac Agent — AGENT_WRAPPED_SESSION_ID present, hook shim installed.
        case agentLaunched
        /// Running inside tmux but not launched by this agent; needs re-wrap for full control.
        case externalTmux
        /// Bare (non-tmux) Ghostty child; needs a new managed tmux session for full control.
        case bareGhostty
    }

    public init(
        id: String,
        kind: Kind,
        tmuxSessionName: String? = nil,
        tmuxWindowName: String? = nil,
        tmuxPaneID: String? = nil,
        repoPath: String,
        lastActivity: Date,
        hookWired: Bool
    ) {
        self.id = id
        self.kind = kind
        self.tmuxSessionName = tmuxSessionName
        self.tmuxWindowName = tmuxWindowName
        self.tmuxPaneID = tmuxPaneID
        self.repoPath = repoPath
        self.lastActivity = lastActivity
        self.hookWired = hookWired
    }
}

// MARK: - Request / Response types

public struct ListDiscoverableSessionsResponse: Codable, Equatable, Sendable {
    public var sessions: [DiscoverableSession]

    public init(sessions: [DiscoverableSession]) {
        self.sessions = sessions
    }
}

public struct AttachSessionRequest: Codable, Equatable, Sendable {
    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

public struct AttachSessionResponse: Codable, Equatable, Sendable {
    public var attachedSession: AttachedSession
    public var foregroundState: ControlForegroundResponse

    public init(attachedSession: AttachedSession, foregroundState: ControlForegroundResponse) {
        self.attachedSession = attachedSession
        self.foregroundState = foregroundState
    }
}
