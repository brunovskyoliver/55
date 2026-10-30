import AgentShared
import Foundation

/// A normalized event emitted by `ClaudeCodeAdapter` whenever the pending-input
/// state of a Wrapped Session changes.
///
/// The adapter fires this on every `.detected` / `.cleared` transition.
/// `DemoControlService` receives it via `ClaudeCodeAdapter.onInputDetection` and
/// bridges it into the Control API state machine so the Owner Device is notified.
public struct AgentInputDetection: Sendable {

    // MARK: - Phase

    public enum Phase: Sendable {
        /// Pending input was detected; the Wrapped Session is now waiting.
        case detected
        /// Pending input was cleared; the Wrapped Session is no longer waiting.
        case cleared
    }

    // MARK: - Classification

    public enum Classification: Sendable {
        /// Claude is requesting permission to run a tool (approve/deny gate).
        case approval
        /// Claude is asking the user a question, potentially with selectable options.
        case question
        /// Claude is waiting for free-form text input.
        case freeformInput
    }

    // MARK: - Confidence / source

    public enum Confidence: Sendable {
        /// Determined from Claude Code hook events (authoritative).
        case hookConfirmed
        /// Inferred from tmux capture-pane or transcript heuristics (requires extra confirmation).
        case uncertain
    }

    public enum Source: Sendable {
        case hook
        case transcript
        case tmux
    }

    // MARK: - Fields

    /// Whether this is a detection or a clearance.
    public var phase: Phase
    /// Semantic classification — determines which Structured Action to offer.
    public var classification: Classification
    /// How confident the adapter is in the detection.
    public var confidence: Confidence
    /// Where the signal came from.
    public var source: Source
    /// The question/prompt text, if available.
    public var prompt: String?
    /// Selectable answer options (non-empty only for `.question` when parsed from hooks).
    public var options: [PendingInputOption]
    /// For `.approval`: the tool name that needs permission.
    public var approvalToolName: String?
    /// Stable UUID for this detection; the same ID is used in both `.detected` and `.cleared`.
    public var requestID: String

    public init(
        phase: Phase,
        classification: Classification,
        confidence: Confidence,
        source: Source,
        prompt: String? = nil,
        options: [PendingInputOption] = [],
        approvalToolName: String? = nil,
        requestID: String
    ) {
        self.phase = phase
        self.classification = classification
        self.confidence = confidence
        self.source = source
        self.prompt = prompt
        self.options = options
        self.approvalToolName = approvalToolName
        self.requestID = requestID
    }
}
