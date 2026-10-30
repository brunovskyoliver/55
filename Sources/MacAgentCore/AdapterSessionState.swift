import Foundation

// MARK: - State machine

/// The ~9 states of a Wrapped Session in the First Agent Adapter.
///
/// Tool-level detail (editing vs. running shell) is **data on `working`**, not separate states.
/// Every transition is recorded in `AdapterStateTransition` with source event and evidence.
public enum AdapterSessionState: Equatable, Sendable {
    /// Launching a new Wrapped Session (tmux + claude not yet confirmed running).
    case launching
    /// Re-attaching to an existing Wrapped Session discovered after a Mac Agent restart.
    case attaching
    /// Claude is up and between turns — waiting for the next prompt.
    case idle
    /// Claude is actively processing. `activeTool` is set while a PreToolUse is outstanding.
    case working(activeTool: ActiveTool?)
    /// Claude is waiting for the user to approve a tool use (hook-confirmed, high confidence).
    case pendingApproval(ApprovalContext)
    /// Claude's last message appears to be a question (heuristic — Uncertain Pending Input).
    case pendingClarification(ClarificationContext)
    /// Claude is waiting for free-form user input (heuristic — Uncertain Pending Input).
    case pendingUserInput
    /// The Claude session has ended.
    case ended(reason: SessionEndReason)
    /// Transient: hook event stream dropped; attempting to re-establish.
    case reconnecting

    // MARK: Display

    public var displayName: String {
        switch self {
        case .launching: return "Launching"
        case .attaching: return "Attaching"
        case .idle: return "Idle"
        case .working(let tool):
            guard let tool else { return "Working" }
            switch tool.kind {
            case .edit: return "Editing — \(tool.name)"
            case .shell: return "Running shell — \(tool.name)"
            case .other: return "Tool — \(tool.name)"
            }
        case .pendingApproval(let ctx): return "Pending Approval (\(ctx.toolName))"
        case .pendingClarification: return "Pending Clarification"
        case .pendingUserInput: return "Pending User Input"
        case .ended(let reason): return "Ended (\(reason.rawValue))"
        case .reconnecting: return "Reconnecting"
        }
    }

    public var isBusy: Bool {
        switch self {
        case .launching, .attaching, .working, .reconnecting: return true
        default: return false
        }
    }

    public var isPendingInput: Bool {
        switch self {
        case .pendingApproval, .pendingClarification, .pendingUserInput: return true
        default: return false
        }
    }
}

// MARK: - Active tool

/// The tool that is currently running inside a `working` state.
public struct ActiveTool: Equatable, Sendable {
    public var name: String
    public var kind: ToolKind
    /// Raw JSON body of the PreToolUse event — for debug display.
    public var rawInput: Data?

    public enum ToolKind: String, Equatable, Sendable {
        case edit       // Write, Edit, NotebookEdit, MultiEdit
        case shell      // Bash
        case other
    }

    public init(name: String, kind: ToolKind, rawInput: Data? = nil) {
        self.name = name
        self.kind = kind
        self.rawInput = rawInput
    }

    /// Classify a tool by name.
    public static func classify(toolName: String, rawInput: Data? = nil) -> ActiveTool {
        let kind: ToolKind
        switch toolName {
        case "Write", "Edit", "MultiEdit", "NotebookEdit": kind = .edit
        case "Bash": kind = .shell
        default: kind = .other
        }
        return ActiveTool(name: toolName, kind: kind, rawInput: rawInput)
    }
}

// MARK: - Approval context

/// Context for a hook-confirmed approval request (`pendingApproval`).
public struct ApprovalContext: Equatable, Sendable {
    /// The tool_name from the outstanding PreToolUse event.
    public var toolName: String
    /// Raw JSON of the tool_input for display.
    public var rawInput: Data?
    /// Menu choices read from tmux capture-pane (may be nil if capture fails).
    public var menuChoices: [String]?
    public var detectedAt: Date

    public init(
        toolName: String,
        rawInput: Data? = nil,
        menuChoices: [String]? = nil,
        detectedAt: Date = Date()
    ) {
        self.toolName = toolName
        self.rawInput = rawInput
        self.menuChoices = menuChoices
        self.detectedAt = detectedAt
    }

    // Equatable ignores rawInput (Data equality is expensive and not needed for state tracking).
    public static func == (lhs: ApprovalContext, rhs: ApprovalContext) -> Bool {
        lhs.toolName == rhs.toolName &&
        lhs.menuChoices == rhs.menuChoices &&
        lhs.detectedAt == rhs.detectedAt
    }
}

// MARK: - Clarification context

/// Context for a heuristic-detected clarification question (`pendingClarification`).
public struct ClarificationContext: Equatable, Sendable {
    public var question: String
    public var suggestedOptions: [String]
    public var detectedAt: Date

    public init(
        question: String,
        suggestedOptions: [String] = [],
        detectedAt: Date = Date()
    ) {
        self.question = question
        self.suggestedOptions = suggestedOptions
        self.detectedAt = detectedAt
    }
}

// MARK: - End reason

public enum SessionEndReason: String, Equatable, Sendable {
    case completed
    case failed
    case interrupted
}

// MARK: - Transition log

/// A single recorded transition in the session state machine.
public struct AdapterStateTransition: Sendable, Identifiable {
    public var id: String
    public var from: AdapterSessionState
    public var to: AdapterSessionState
    public var triggeringEvent: String
    public var evidence: String
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        from: AdapterSessionState,
        to: AdapterSessionState,
        triggeringEvent: String,
        evidence: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.triggeringEvent = triggeringEvent
        self.evidence = evidence
        self.timestamp = timestamp
    }
}
