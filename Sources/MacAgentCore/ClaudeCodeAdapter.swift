import AgentShared
import Foundation

/// The First Agent Adapter — manages the state machine for one Claude Code Wrapped Session.
///
/// Feed hook events from `AgentEventServer` via `ingest(_:)`. The adapter:
/// - Transitions through ~9 session states driven by hook events.
/// - Discriminates approval-vs-idle using **event ordering** (outstanding PreToolUse), not
///   message text (per D4 — locale-fragile message matching is secondary only).
/// - Detects clarification eagerly on `Stop` by reading the transcript tail (Uncertain).
/// - Reads approval menu choices from tmux `capture-pane` (best-effort).
/// - Updates `debugState` on every transition for the debug window (always main thread).
///
/// Thread safety: all mutable state is protected by `NSLock`; debug state updates are
/// dispatched to the main queue.
public final class ClaudeCodeAdapter: @unchecked Sendable {
    public let debugState: AdapterDebugState

    /// Called on every Pending Input detection or clearance.
    /// The closure runs on whatever thread the hook event arrives on (not necessarily the main thread).
    /// Implementations must be thread-safe (`@Sendable`).
    public var onInputDetection: (@Sendable (AgentInputDetection) -> Void)?

    /// Called on every state transition (excluding no-op same→same transitions).
    /// Runs on the hook-event delivery thread. Implementations must be thread-safe.
    public var onStateTransition: (@Sendable (_ from: AdapterSessionState, _ to: AdapterSessionState) -> Void)?

    // MARK: - Private state

    private let lock = NSAdapterLock()
    private var _state: AdapterSessionState = .idle
    // Outstanding PreToolUse: tool name with no matching PostToolUse yet.
    private var outstandingToolName: String?
    private var outstandingToolRawInput: Data?
    // Stable ID for the current pending detection; nil when not pending.
    private var _currentDetectionID: String?
    // Classification of the current detection (needed for clear events).
    private var _currentDetectionClassification: AgentInputDetection.Classification?

    private let executor: any ProcessCommandExecuting

    // Limits to prevent unbounded growth in debug collections.
    private static let maxTransitions = 200
    private static let maxHookEvents = 100
    private static let maxTranscriptLines = 50
    private static let maxDecisions = 50

    // MARK: - Init

    public init(
        debugState: AdapterDebugState = AdapterDebugState(),
        executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor()
    ) {
        self.debugState = debugState
        self.executor = executor
    }

    // MARK: - Lifecycle entry points

    /// Call immediately after a new Wrapped Session is launched.
    public func sessionLaunched(
        wrappedSessionID: String,
        tmuxSessionName: String,
        tmuxWindowName: String,
        hookServerPort: UInt16
    ) {
        let old = lock.withLock { () -> AdapterSessionState in
            let prev = _state
            _state = .launching
            return prev
        }
        updateDebugMeta(
            wrappedSessionID: wrappedSessionID,
            tmuxSessionName: tmuxSessionName,
            tmuxWindowName: tmuxWindowName,
            hookServerPort: hookServerPort
        )
        recordTransition(
            from: old, to: .launching,
            event: "sessionLaunched",
            evidence: "New Wrapped Session started: tmux/\(tmuxSessionName)"
        )
        pushState(.launching)
    }

    /// Call when re-attaching to an existing Wrapped Session (reuse path).
    public func sessionAttaching(
        wrappedSessionID: String,
        tmuxSessionName: String,
        tmuxWindowName: String,
        hookServerPort: UInt16
    ) {
        let old = lock.withLock { () -> AdapterSessionState in
            let prev = _state
            _state = .attaching
            return prev
        }
        updateDebugMeta(
            wrappedSessionID: wrappedSessionID,
            tmuxSessionName: tmuxSessionName,
            tmuxWindowName: tmuxWindowName,
            hookServerPort: hookServerPort
        )
        recordTransition(
            from: old, to: .attaching,
            event: "sessionAttaching",
            evidence: "Re-attaching to existing Wrapped Session: tmux/\(tmuxSessionName)"
        )
        pushState(.attaching)
    }

    /// Record a non-fatal adapter error.
    public func recordError(_ message: String) {
        appendDecision("ERROR: \(message)")
        DispatchQueue.main.async { [self] in
            debugState.errors.append(.init(message: message))
        }
    }

    // MARK: - Event ingestion

    /// Ingest a hook event. Called by `AgentEventServer` on every received event.
    public func ingest(_ event: ClaudeHookEvent) {
        // Record Claude's session_id and transcript_path from the first event.
        lock.withLock {
            if debugState.claudeSessionID == nil {
                DispatchQueue.main.async { [self] in
                    self.debugState.claudeSessionID = event.payload.sessionId
                    self.debugState.connectionStatus = .receiving
                }
            }
            if debugState.transcriptPath == nil, let tp = event.payload.transcriptPath {
                DispatchQueue.main.async { [self] in
                    self.debugState.transcriptPath = tp
                }
            }
        }

        appendHookEventSummary(event)
        transition(on: event)
    }

    // MARK: - State machine

    private func transition(on event: ClaudeHookEvent) {
        let current = lock.withLock { _state }

        switch event.kind {
        case .sessionStart:
            clearOutstandingTool()
            move(to: .idle, event: event, evidence: "SessionStart — Claude session initialised")

        case .sessionEnd:
            clearOutstandingTool()
            emitClearedIfPending()
            move(to: .ended(reason: .completed), event: event, evidence: "SessionEnd hook received")
            DispatchQueue.main.async { [self] in debugState.pendingInputDetail = nil }

        case .userPromptSubmit:
            // User sent a prompt — Claude is now working.
            clearOutstandingTool()
            emitClearedIfPending()
            move(to: .working(activeTool: nil), event: event, evidence: "UserPromptSubmit — Claude processing prompt")
            DispatchQueue.main.async { [self] in debugState.pendingInputDetail = nil }

        case .preToolUse:
            let toolName = event.payload.toolName ?? "UnknownTool"
            let rawBody: Data? = event.rawBody.isEmpty ? nil : event.rawBody
            let tool = ActiveTool.classify(toolName: toolName, rawInput: rawBody)
            lock.withLock {
                outstandingToolName = toolName
                outstandingToolRawInput = rawBody
            }
            move(to: .working(activeTool: tool), event: event, evidence: "PreToolUse: \(toolName) starting")

        case .postToolUse:
            let toolName = event.payload.toolName ?? ""
            let wasPending = lock.withLock { () -> Bool in
                let was = _state.isPendingInput
                if outstandingToolName == toolName || toolName.isEmpty {
                    outstandingToolName = nil
                    outstandingToolRawInput = nil
                }
                return was
            }
            if wasPending {
                emitClearedIfPending()
                DispatchQueue.main.async { [self] in debugState.pendingInputDetail = nil }
            }
            move(to: .working(activeTool: nil), event: event, evidence: "PostToolUse: \(toolName) completed")

        case .notification:
            handleNotification(event: event, current: current)

        case .stop:
            handleStop(event: event)

        case .subagentStop:
            // Subagent finished; parent may continue working.
            move(to: .working(activeTool: nil), event: event, evidence: "SubagentStop — subagent complete, parent may continue")

        case .preCompact, .unknown:
            appendDecision("Received \(event.payload.hookEventName) — no state change")
        }
    }

    // MARK: - Notification handling

    private func handleNotification(event: ClaudeHookEvent, current: AdapterSessionState) {
        let (outstanding, rawInput) = lock.withLock { (outstandingToolName, outstandingToolRawInput) }

        if let toolName = outstanding {
            // Primary signal: outstanding PreToolUse with no PostToolUse → pending for that tool.
            // (D4: event ordering is the discriminator, NOT the notification message text.)
            //
            // Semantic classification: AskUserQuestion → question (reply path);
            // all other tools → approval (approve/deny gate).
            let menuChoices = readApprovalMenuChoices()

            if toolName == "AskUserQuestion" {
                // ⚠️ AskUserQuestion hook behavior is not yet fully documented.
                // Phase 0 spike confirms: (a) whether PreToolUse + Notification fire in this sequence,
                // (b) the tool_input schema for options, and (c) the answer-delivery mechanism.
                // Until verified, we classify as .question / .hookConfirmed and parse options
                // from rawInput best-effort. The UI degrades to reply-text when options is empty.
                let options = parseAskUserQuestionOptions(from: rawInput)
                let prompt = parseAskUserQuestionPrompt(from: rawInput)
                let context = ClarificationContext(
                    question: prompt ?? "Claude is asking a question.",
                    suggestedOptions: options.map(\.label),
                    detectedAt: Date()
                )
                move(
                    to: .pendingClarification(context), event: event,
                    evidence: "Notification + outstanding PreToolUse[AskUserQuestion] → pendingClarification (hook-confirmed question)"
                )
                let detail = AdapterDebugState.PendingInputDetail(
                    kind: .clarification,
                    confidence: .hookConfirmed,
                    source: .hook,
                    evidence: "Notification + PreToolUse[AskUserQuestion] outstanding — Claude asked a question",
                    question: prompt,
                    options: options.map(\.label),
                    detectedAt: Date()
                )
                DispatchQueue.main.async { [self] in debugState.pendingInputDetail = detail }
                emitDetected(
                    classification: .question,
                    confidence: .hookConfirmed,
                    source: .hook,
                    prompt: prompt,
                    options: options
                )
            } else {
                let context = ApprovalContext(
                    toolName: toolName,
                    rawInput: rawInput,
                    menuChoices: menuChoices,
                    detectedAt: Date()
                )
                move(
                    to: .pendingApproval(context), event: event,
                    evidence: "Notification + outstanding PreToolUse[\(toolName)] → pendingApproval (hook-confirmed)"
                )
                let detail = AdapterDebugState.PendingInputDetail(
                    kind: .approval,
                    confidence: .hookConfirmed,
                    source: .hook,
                    evidence: "Notification received while PreToolUse[\(toolName)] was outstanding (no PostToolUse yet)",
                    approvalToolName: toolName,
                    detectedAt: Date()
                )
                DispatchQueue.main.async { [self] in debugState.pendingInputDetail = detail }
                emitDetected(
                    classification: .approval,
                    confidence: .hookConfirmed,
                    source: .hook,
                    approvalToolName: toolName
                )
            }
        } else {
            // No outstanding tool → idle waiting for free-form input (Uncertain heuristic).
            move(
                to: .pendingUserInput, event: event,
                evidence: "Notification with no outstanding tool → pendingUserInput (Uncertain)"
            )
            let detail = AdapterDebugState.PendingInputDetail(
                kind: .userInput,
                confidence: .uncertain,
                source: .tmux,
                evidence: "Notification received with no outstanding tool — Claude is idle-waiting",
                detectedAt: Date()
            )
            DispatchQueue.main.async { [self] in debugState.pendingInputDetail = detail }
            emitDetected(
                classification: .freeformInput,
                confidence: .uncertain,
                source: .tmux
            )
        }
    }

    // MARK: - Stop handling

    private func handleStop(event: ClaudeHookEvent) {
        // Eagerly read the transcript tail to distinguish clarification from work-complete.
        let transcriptPath = lock.withLock { debugState.transcriptPath }
        let tail = transcriptPath.flatMap { readTranscriptTail(at: $0) }

        if let tail, let clarification = detectClarification(in: tail) {
            // Question-shaped tail → pendingClarification (Uncertain heuristic).
            let context = ClarificationContext(
                question: clarification.question,
                suggestedOptions: clarification.options,
                detectedAt: Date()
            )
            move(
                to: .pendingClarification(context), event: event,
                evidence: "Stop + transcript tail question-shaped: \"\(clarification.question.prefix(80))...\""
            )
            let detail = AdapterDebugState.PendingInputDetail(
                kind: .clarification,
                confidence: .uncertain,
                source: .transcript,
                evidence: "Stop hook; transcript tail ends with question-shaped message",
                question: clarification.question,
                options: clarification.options,
                detectedAt: Date()
            )
            DispatchQueue.main.async { [self] in
                self.debugState.pendingInputDetail = detail
                self.debugState.transcriptTail = tail
            }
            emitDetected(
                classification: .question,
                confidence: .uncertain,
                source: .transcript,
                prompt: clarification.question,
                options: clarification.options.enumerated().map { idx, label in
                    PendingInputOption(id: "\(idx)", label: label)
                }
            )
        } else {
            // Turn complete — move to idle. Clear any stale pending detail.
            clearOutstandingTool()
            emitClearedIfPending()
            move(to: .idle, event: event, evidence: "Stop hook — turn complete")
            DispatchQueue.main.async { [self] in
                self.debugState.pendingInputDetail = nil
                if let tail { self.debugState.transcriptTail = tail }
            }
        }
    }

    // MARK: - Internal helpers

    private func clearOutstandingTool() {
        lock.withLock {
            outstandingToolName = nil
            outstandingToolRawInput = nil
        }
    }

    private func move(to next: AdapterSessionState, event: ClaudeHookEvent, evidence: String) {
        let prev = lock.withLock { () -> AdapterSessionState in
            let p = _state
            // Don't record a no-op transition for identical states.
            if p == next { return p }
            _state = next
            return p
        }
        guard prev != next else { return }
        recordTransition(from: prev, to: next, event: event.payload.hookEventName, evidence: evidence)
        pushState(next)
    }

    private func pushState(_ state: AdapterSessionState) {
        DispatchQueue.main.async { [self] in
            debugState.sessionState = state
        }
    }

    private func recordTransition(
        from: AdapterSessionState,
        to: AdapterSessionState,
        event: String,
        evidence: String
    ) {
        let t = AdapterStateTransition(
            from: from, to: to,
            triggeringEvent: event,
            evidence: evidence
        )
        let label = "[\(event)] \(from.displayName) → \(to.displayName)"
        appendDecision("\(label): \(evidence)")

        DispatchQueue.main.async { [self] in
            var transitions = debugState.stateTransitions
            transitions.append(t)
            if transitions.count > Self.maxTransitions { transitions.removeFirst() }
            debugState.stateTransitions = transitions
        }

        onStateTransition?(from, to)
    }

    private func appendHookEventSummary(_ event: ClaudeHookEvent) {
        let summary = AdapterDebugState.HookEventSummary(
            eventName: event.payload.hookEventName,
            toolName: event.payload.toolName,
            sessionId: event.payload.sessionId,
            receivedAt: event.receivedAt
        )
        DispatchQueue.main.async { [self] in
            var events = debugState.recentHookEvents
            events.append(summary)
            if events.count > Self.maxHookEvents { events.removeFirst() }
            debugState.recentHookEvents = events
        }
    }

    private func appendDecision(_ message: String) {
        let ts = Date().formatted(.dateTime.hour().minute().second())
        let line = "[\(ts)] \(message)"
        DispatchQueue.main.async { [self] in
            var decisions = debugState.adapterDecisions
            decisions.append(line)
            if decisions.count > Self.maxDecisions { decisions.removeFirst() }
            debugState.adapterDecisions = decisions
        }
    }

    private func updateDebugMeta(
        wrappedSessionID: String,
        tmuxSessionName: String,
        tmuxWindowName: String,
        hookServerPort: UInt16
    ) {
        DispatchQueue.main.async { [self] in
            debugState.wrappedSessionID = wrappedSessionID
            debugState.tmuxSessionName = tmuxSessionName
            debugState.tmuxWindowName = tmuxWindowName
            debugState.hookServerPort = hookServerPort
            debugState.connectionStatus = .listening(port: hookServerPort)
        }
    }

    // MARK: - Detection emission helpers

    /// Emit a `.detected` event, generating a new stable `requestID` for the detection.
    private func emitDetected(
        classification: AgentInputDetection.Classification,
        confidence: AgentInputDetection.Confidence,
        source: AgentInputDetection.Source,
        prompt: String? = nil,
        options: [PendingInputOption] = [],
        approvalToolName: String? = nil
    ) {
        let requestID = UUID().uuidString
        lock.withLock {
            _currentDetectionID = requestID
            _currentDetectionClassification = classification
        }
        onInputDetection?(AgentInputDetection(
            phase: .detected,
            classification: classification,
            confidence: confidence,
            source: source,
            prompt: prompt,
            options: options,
            approvalToolName: approvalToolName,
            requestID: requestID
        ))
    }

    /// Emit a `.cleared` event if there is a current detection, then clear tracking state.
    private func emitClearedIfPending() {
        let (requestID, classification) = lock.withLock { () -> (String?, AgentInputDetection.Classification?) in
            let id = _currentDetectionID
            let cls = _currentDetectionClassification
            _currentDetectionID = nil
            _currentDetectionClassification = nil
            return (id, cls)
        }
        guard let requestID, let classification else { return }
        onInputDetection?(AgentInputDetection(
            phase: .cleared,
            classification: classification,
            confidence: .hookConfirmed,
            source: .hook,
            requestID: requestID
        ))
    }

    // MARK: - AskUserQuestion option parsing
    // ⚠️ Phase 0 spike required to validate the actual tool_input schema.
    // Best-effort parsing until confirmed. Returns empty array when schema is unexpected.

    private func parseAskUserQuestionOptions(from rawInput: Data?) -> [PendingInputOption] {
        guard let rawInput, !rawInput.isEmpty else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: rawInput) as? [String: Any] else { return [] }
        // Attempt to read the hook payload's tool_input.options array.
        // Expected shape (unverified): { "tool_input": { "options": ["Option A", "Option B", ...] } }
        let toolInput = json["tool_input"] as? [String: Any] ?? json
        guard let rawOptions = toolInput["options"] as? [String] else { return [] }
        return rawOptions.enumerated().map { idx, label in PendingInputOption(id: "\(idx)", label: label) }
    }

    private func parseAskUserQuestionPrompt(from rawInput: Data?) -> String? {
        guard let rawInput, !rawInput.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: rawInput) as? [String: Any] else { return nil }
        let toolInput = json["tool_input"] as? [String: Any] ?? json
        return toolInput["question"] as? String ?? toolInput["prompt"] as? String
    }

    // MARK: - Transcript tail reading

    private func readTranscriptTail(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let tail = lines.suffix(Self.maxTranscriptLines).joined(separator: "\n")
        return tail.isEmpty ? nil : tail
    }

    // MARK: - Clarification detection

    private struct ClarificationResult {
        var question: String
        var options: [String]
    }

    private func detectClarification(in tail: String) -> ClarificationResult? {
        let lines = tail.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let lastLine = lines.last else { return nil }

        // Signal 1: last non-empty line ends with '?'
        let isQuestion = lastLine.hasSuffix("?")

        // Signal 2: numbered or bulleted option list near the end
        let optionLines = lines.suffix(20).filter { line in
            line.range(of: #"^\s*\d+[\)\.:]"#, options: .regularExpression) != nil ||
            line.range(of: #"^\s*[-•*]\s"#, options: .regularExpression) != nil
        }

        guard isQuestion || !optionLines.isEmpty else { return nil }

        // Extract the question text
        let question: String
        if isQuestion {
            question = lastLine
        } else {
            // Last line before the options, or last non-option non-empty line
            question = lines.last(where: { line in
                !optionLines.contains(line) && !line.isEmpty
            }) ?? lastLine
        }

        return ClarificationResult(question: question, options: optionLines)
    }

    // MARK: - Approval menu choices (capture-pane heuristic)

    private func readApprovalMenuChoices() -> [String]? {
        let sessionName = lock.withLock { debugState.tmuxSessionName }
        guard let session = sessionName else { return nil }

        guard let result = try? executor.run(
            executable: "tmux",
            arguments: ["capture-pane", "-p", "-t", session]
        ) else { return nil }

        let text = String(decoding: result.stdout, as: UTF8.self)
        let choices = text.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(of: #"^\d+[\)\.>]"#, options: .regularExpression) != nil else {
                return nil
            }
            return trimmed
        }
        return choices.isEmpty ? nil : choices
    }
}

// MARK: - Lock helper

private final class NSAdapterLock: @unchecked Sendable {
    private let underlying = NSLock()

    @discardableResult
    func withLock<Value>(_ body: () -> Value) -> Value {
        underlying.lock()
        defer { underlying.unlock() }
        return body()
    }
}
