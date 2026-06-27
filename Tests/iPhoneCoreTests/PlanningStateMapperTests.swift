import AgentShared
import iPhoneCore
import MacAgentCore
import XCTest

final class PlanningStateMapperTests: XCTestCase {
    func testMapsForegroundResponseIntoPlanningCenteredState() throws {
        let response = try DemoControlService().foregroundState()
        let state = try PlanningStateMapper().map(response)

        XCTAssertEqual(state.activePlanningArtifact.id, "issue-2")
        XCTAssertEqual(state.activePlanningArtifact.label, "Issue #2")
        XCTAssertEqual(state.activePlanningArtifact.affordanceTitle, "Issue Planning")
        XCTAssertEqual(state.activePlanningArtifact.state, "Open")
        XCTAssertNotNil(state.configuredRepositoryPath)
        XCTAssertNil(state.attachedSession)
        XCTAssertEqual(state.fileReview.title, "File Review")
        XCTAssertTrue(state.fileReview.detail.contains("Changed files: 0"))
        XCTAssertEqual(state.auditTimeline.title, "Audit Timeline")
        XCTAssertEqual(state.auditTimeline.entries.count, 0)

        let guardedStop = try XCTUnwrap(state.structuredActions.first { $0.id == "guarded-stop" })
        XCTAssertFalse(guardedStop.isAvailable)
        XCTAssertEqual(guardedStop.reason, "No Agent Session")
        XCTAssertNil(state.structuredActions.first { $0.id == "commit" })
        XCTAssertNil(state.structuredActions.first { $0.id == "push" })
    }

    func testLoaderFetchesAndMapsForegroundState() async throws {
        let loader = ForegroundStateLoader(client: FakeForegroundStateClient(response: try DemoControlService().foregroundState()))

        let state = try await loader.load()

        XCTAssertEqual(state.activePlanningArtifact.title, "Scaffold Apple App Codebase with a demo Control API path")
        XCTAssertNil(state.attachedSession)
    }

    func testMapperDistinguishesPRReviewAffordance() throws {
        let response = ControlForegroundResponse(
            planningArtifacts: [
                PlanningArtifact(
                    id: "pr-4",
                    kind: .pullRequest,
                    number: 4,
                    title: "Review wrapped session launch",
                    url: URL(string: "https://github.com/brunovskyoliver/55/pull/4")!,
                    state: "open"
                )
            ],
            activePlanningArtifactID: "pr-4",
            attachedSessions: [],
            structuredActionAvailability: StructuredActionAvailability(
                reply: StructuredActionState(isAvailable: false, reason: "No Pending Input"),
                approve: StructuredActionState(isAvailable: false, reason: "No approval request"),
                deny: StructuredActionState(isAvailable: false, reason: "No approval request"),
                draftComment: StructuredActionState(isAvailable: false, reason: "No draft"),
                guardedStop: StructuredActionState(isAvailable: false, reason: "No session")
            ),
            fileReview: FileReviewPlaceholder(status: "placeholder", summary: "Unavailable", changedFileCount: 0),
            auditTimeline: AuditTimelinePlaceholder(summary: "Audit Timeline", entries: [])
        )

        let state = try PlanningStateMapper().map(response)

        XCTAssertEqual(state.activePlanningArtifact.label, "PR #4")
        XCTAssertEqual(state.activePlanningArtifact.affordanceTitle, "PR Review")
    }

    func testMapperCarriesCompactAuditTimelineEntries() throws {
        let occurredAt = Date(timeIntervalSince1970: 30)
        let response = ControlForegroundResponse(
            planningArtifacts: [
                PlanningArtifact(
                    id: "issue-6",
                    kind: .issue,
                    number: 6,
                    title: "Persist Session Event Log",
                    url: URL(string: "https://github.com/brunovskyoliver/55/issues/6")!,
                    state: "open"
                )
            ],
            activePlanningArtifactID: "issue-6",
            attachedSessions: [],
            structuredActionAvailability: StructuredActionAvailability(
                reply: StructuredActionState(isAvailable: false, reason: "No Pending Input"),
                approve: StructuredActionState(isAvailable: false, reason: "No approval request"),
                deny: StructuredActionState(isAvailable: false, reason: "No approval request"),
                draftComment: StructuredActionState(isAvailable: false, reason: "No draft"),
                guardedStop: StructuredActionState(isAvailable: false, reason: "No session")
            ),
            fileReview: FileReviewPlaceholder(status: "placeholder", summary: "Unavailable", changedFileCount: 0),
            auditTimeline: AuditTimelinePlaceholder(
                summary: "Audit Timeline",
                entries: [
                    AuditTimelineEntry(
                        id: "event-1",
                        title: "Wrapped Session running",
                        detail: "Clean worktree on main at abcdef123456.",
                        occurredAt: occurredAt
                    )
                ]
            )
        )

        let state = try PlanningStateMapper().map(response)

        XCTAssertEqual(state.auditTimeline.entries.count, 1)
        XCTAssertEqual(state.auditTimeline.entries.first?.id, "event-1")
        XCTAssertEqual(state.auditTimeline.entries.first?.title, "Wrapped Session running")
        XCTAssertEqual(state.auditTimeline.entries.first?.occurredAt, occurredAt)
    }

    func testMapperCarriesUncertainReplyConfirmationRequirement() throws {
        let response = ControlForegroundResponse(
            planningArtifacts: [
                PlanningArtifact(
                    id: "issue-7",
                    kind: .issue,
                    number: 7,
                    title: "Detect Pending Input and send guarded replies",
                    url: URL(string: "https://github.com/brunovskyoliver/55/issues/7")!,
                    state: "open"
                )
            ],
            activePlanningArtifactID: "issue-7",
            attachedSessions: [],
            pendingInput: PendingInputState(
                status: .uncertain,
                source: .tmuxHeuristic,
                prompt: "tmux prompt",
                detectedAt: Date(timeIntervalSince1970: 40)
            ),
            structuredActionAvailability: StructuredActionAvailability(
                reply: StructuredActionState(
                    isAvailable: true,
                    reason: "Uncertain Pending Input; confirmation required",
                    requiresConfirmation: true
                ),
                approve: StructuredActionState(isAvailable: false, reason: "No approval request"),
                deny: StructuredActionState(isAvailable: false, reason: "No approval request"),
                draftComment: StructuredActionState(isAvailable: false, reason: "No draft"),
                guardedStop: StructuredActionState(isAvailable: false, reason: "No session")
            ),
            fileReview: FileReviewPlaceholder(status: "placeholder", summary: "Unavailable", changedFileCount: 0),
            auditTimeline: AuditTimelinePlaceholder(summary: "Audit Timeline", entries: [])
        )

        let state = try PlanningStateMapper().map(response)
        let reply = try XCTUnwrap(state.structuredActions.first { $0.id == "reply" })

        XCTAssertTrue(reply.isAvailable)
        XCTAssertTrue(reply.requiresConfirmation)
    }

    func testMapperCarriesPendingApprovalRequestAndActions() throws {
        let requestedAt = Date(timeIntervalSince1970: 50)
        let response = ControlForegroundResponse(
            planningArtifacts: [
                PlanningArtifact(
                    id: "issue-8",
                    kind: .issue,
                    number: 8,
                    title: "Handle Claude Code approve and deny Structured Actions",
                    url: URL(string: "https://github.com/brunovskyoliver/55/issues/8")!,
                    state: "open"
                )
            ],
            activePlanningArtifactID: "issue-8",
            attachedSessions: [
                AttachedSession(
                    planningArtifactID: "issue-8",
                    session: AgentSession(
                        id: "session-8",
                        displayName: "Claude Code Wrapped Session",
                        state: .waitingForApproval,
                        summary: "Waiting for approval."
                    )
                )
            ],
            pendingApprovalRequest: ApprovalRequestState(
                requestID: "approval-1",
                source: .claudeCodeHook,
                title: "Allow command?",
                detail: "Claude Code wants to run swift test.",
                requestedAt: requestedAt
            ),
            structuredActionAvailability: StructuredActionAvailability(
                reply: StructuredActionState(isAvailable: false, reason: "No Pending Input"),
                approve: StructuredActionState(isAvailable: true, reason: "Approve: Allow command?", requiresConfirmation: true),
                deny: StructuredActionState(isAvailable: true, reason: "Deny: Allow command?", requiresConfirmation: true),
                draftComment: StructuredActionState(isAvailable: false, reason: "No draft"),
                guardedStop: StructuredActionState(isAvailable: true, reason: "Wrapped Session is active")
            ),
            fileReview: FileReviewPlaceholder(status: "placeholder", summary: "Unavailable", changedFileCount: 0),
            auditTimeline: AuditTimelinePlaceholder(
                summary: "Audit Timeline",
                entries: [
                    AuditTimelineEntry(
                        id: "event-approval",
                        title: "Approval request detected",
                        detail: "Allow command?",
                        occurredAt: requestedAt
                    )
                ]
            )
        )

        let state = try PlanningStateMapper().map(response)

        XCTAssertEqual(state.attachedSession?.stateText, "Waiting for Approval")
        XCTAssertEqual(state.pendingApprovalRequest?.id, "approval-1")
        XCTAssertEqual(state.pendingApprovalRequest?.title, "Allow command?")
        XCTAssertEqual(state.auditTimeline.entries.first?.title, "Approval request detected")
        let approve = try XCTUnwrap(state.structuredActions.first { $0.id == "approve" })
        let deny = try XCTUnwrap(state.structuredActions.first { $0.id == "deny" })
        XCTAssertTrue(approve.isAvailable)
        XCTAssertTrue(approve.requiresConfirmation)
        XCTAssertTrue(deny.isAvailable)
        XCTAssertTrue(deny.requiresConfirmation)
    }

    func testMapperCarriesFileReviewFiles() throws {
        let response = ControlForegroundResponse(
            planningArtifacts: [
                PlanningArtifact(
                    id: "issue-9",
                    kind: .issue,
                    number: 9,
                    title: "Build File Review",
                    url: URL(string: "https://github.com/brunovskyoliver/55/issues/9")!,
                    state: "open"
                )
            ],
            activePlanningArtifactID: "issue-9",
            attachedSessions: [],
            structuredActionAvailability: StructuredActionAvailability(
                reply: StructuredActionState(isAvailable: false, reason: "No Pending Input"),
                approve: StructuredActionState(isAvailable: false, reason: "No approval request"),
                deny: StructuredActionState(isAvailable: false, reason: "No approval request"),
                draftComment: StructuredActionState(isAvailable: false, reason: "No draft"),
                guardedStop: StructuredActionState(isAvailable: false, reason: "No session")
            ),
            fileReview: FileReviewState(
                status: .changesAvailable,
                summary: "1 changed file: 0 pre-existing, 1 Agent Session.",
                changedFileCount: 1,
                preExistingChangeCount: 0,
                agentSessionChangeCount: 1,
                files: [
                    FileReviewFile(
                        path: "Sources/App.swift",
                        ownership: .agentSession,
                        changeKind: .modified,
                        additions: 4,
                        deletions: 1,
                        summary: "Modified, +4/-1.",
                        riskSignals: ["Large change"],
                        selectedHunks: [
                            FileReviewHunk(
                                id: "Sources/App.swift:0",
                                header: "@@ -1 +1 @@",
                                lines: ["-old", "+new"]
                            )
                        ]
                    )
                ]
            ),
            auditTimeline: AuditTimelinePlaceholder(summary: "Audit Timeline", entries: [])
        )

        let state = try PlanningStateMapper().map(response)
        let file = try XCTUnwrap(state.fileReview.files.first)

        XCTAssertEqual(state.fileReview.changedFileCount, 1)
        XCTAssertEqual(state.fileReview.agentSessionChangeCount, 1)
        XCTAssertEqual(file.ownershipTitle, "Agent Session")
        XCTAssertEqual(file.changeKindTitle, "Modified")
        XCTAssertEqual(file.changeSize, "+4 / -1")
        XCTAssertEqual(file.riskSignals, ["Large change"])
        XCTAssertEqual(file.selectedHunks.first?.header, "@@ -1 +1 @@")
    }

    func testMapperRejectsMissingActivePlanningArtifact() {
        let response = ControlForegroundResponse(
            planningArtifacts: [],
            activePlanningArtifactID: nil,
            attachedSessions: [],
            structuredActionAvailability: StructuredActionAvailability(
                reply: StructuredActionState(isAvailable: false, reason: "No Pending Input"),
                approve: StructuredActionState(isAvailable: false, reason: "No approval request"),
                deny: StructuredActionState(isAvailable: false, reason: "No approval request"),
                draftComment: StructuredActionState(isAvailable: false, reason: "No draft"),
                guardedStop: StructuredActionState(isAvailable: false, reason: "No session")
            ),
            fileReview: FileReviewPlaceholder(status: "placeholder", summary: "Unavailable", changedFileCount: 0),
            auditTimeline: AuditTimelinePlaceholder(summary: "Audit Timeline", entries: [])
        )

        XCTAssertThrowsError(try PlanningStateMapper().map(response)) { error in
            XCTAssertEqual(error as? PlanningStateMapperError, .missingActivePlanningArtifact)
        }
    }
}

private struct FakeForegroundStateClient: ForegroundStateClient {
    let response: ControlForegroundResponse

    func fetchForegroundState() async throws -> ControlForegroundResponse {
        response
    }
}
