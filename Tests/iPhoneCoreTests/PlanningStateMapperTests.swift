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
        XCTAssertEqual(state.auditTimeline.title, "Audit Timeline placeholder")

        let guardedStop = try XCTUnwrap(state.structuredActions.first { $0.id == "guarded-stop" })
        XCTAssertFalse(guardedStop.isAvailable)
        XCTAssertEqual(guardedStop.reason, "No Agent Session")
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
            auditTimeline: AuditTimelinePlaceholder(summary: "Audit Timeline placeholder", entries: [])
        )

        let state = try PlanningStateMapper().map(response)

        XCTAssertEqual(state.activePlanningArtifact.label, "PR #4")
        XCTAssertEqual(state.activePlanningArtifact.affordanceTitle, "PR Review")
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
            auditTimeline: AuditTimelinePlaceholder(summary: "Audit Timeline placeholder", entries: [])
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
