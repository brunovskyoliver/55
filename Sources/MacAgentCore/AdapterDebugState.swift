import Foundation

/// Observable projection of `ClaudeCodeAdapter` internals for the debug window.
///
/// All mutations must happen on the main thread (the adapter uses `DispatchQueue.main.async`
/// for every update). Marked `@unchecked Sendable` so it can be captured in `@Sendable`
/// closures crossing concurrency boundaries inside the adapter.
public final class AdapterDebugState: ObservableObject, @unchecked Sendable {
    // MARK: - Session identity

    @Published public var wrappedSessionID: String?
    @Published public var claudeSessionID: String?
    @Published public var transcriptPath: String?

    // MARK: - tmux

    @Published public var tmuxSessionName: String?
    @Published public var tmuxWindowName: String?

    // MARK: - State machine

    @Published public var sessionState: AdapterSessionState = .idle
    @Published public var stateTransitions: [AdapterStateTransition] = []

    // MARK: - Pending input

    @Published public var pendingInputDetail: PendingInputDetail?

    // MARK: - Hook stream

    @Published public var recentHookEvents: [HookEventSummary] = []
    @Published public var hookServerPort: UInt16?
    @Published public var connectionStatus: ConnectionStatus = .disconnected

    // MARK: - Transcript tail

    @Published public var transcriptTail: String?

    // MARK: - Adapter decisions & errors

    @Published public var adapterDecisions: [String] = []
    @Published public var errors: [ErrorEntry] = []

    public init() {}

    // MARK: - Nested types

    public enum ConnectionStatus: Equatable, Sendable {
        case disconnected
        case listening(port: UInt16)
        case receiving
        case error(String)

        public var displayText: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .listening(let port): return "Listening on port \(port)"
            case .receiving: return "Receiving events"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    // MARK: Pending input detail

    /// Structured detail about the current pending input detection.
    public struct PendingInputDetail: Sendable {
        public var kind: Kind
        public var confidence: Confidence
        public var source: Source
        public var evidence: String
        public var question: String?
        public var options: [String]
        public var approvalToolName: String?
        public var detectedAt: Date

        public enum Kind: String, Sendable {
            case approval = "Approval"
            case clarification = "Clarification"
            case userInput = "User Input"
        }

        public enum Confidence: String, Sendable {
            case hookConfirmed = "Hook-confirmed"
            case uncertain = "Uncertain (heuristic)"
        }

        public enum Source: String, Sendable {
            case hook = "Hook"
            case transcript = "Transcript tail"
            case tmux = "tmux capture-pane"
        }

        public init(
            kind: Kind,
            confidence: Confidence,
            source: Source,
            evidence: String,
            question: String? = nil,
            options: [String] = [],
            approvalToolName: String? = nil,
            detectedAt: Date = Date()
        ) {
            self.kind = kind
            self.confidence = confidence
            self.source = source
            self.evidence = evidence
            self.question = question
            self.options = options
            self.approvalToolName = approvalToolName
            self.detectedAt = detectedAt
        }
    }

    // MARK: Hook event summary

    public struct HookEventSummary: Identifiable, Sendable {
        public var id: String
        public var eventName: String
        public var toolName: String?
        public var sessionId: String
        public var receivedAt: Date

        public init(
            id: String = UUID().uuidString,
            eventName: String,
            toolName: String? = nil,
            sessionId: String,
            receivedAt: Date
        ) {
            self.id = id
            self.eventName = eventName
            self.toolName = toolName
            self.sessionId = sessionId
            self.receivedAt = receivedAt
        }
    }

    // MARK: Error entry

    public struct ErrorEntry: Identifiable, Sendable {
        public var id: String
        public var message: String
        public var occurredAt: Date

        public init(
            id: String = UUID().uuidString,
            message: String,
            occurredAt: Date = Date()
        ) {
            self.id = id
            self.message = message
            self.occurredAt = occurredAt
        }
    }
}
