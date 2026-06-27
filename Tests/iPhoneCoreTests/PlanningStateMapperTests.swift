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
        XCTAssertEqual(state.activePlanningArtifact.state, "Open")
        XCTAssertEqual(state.attachedSession?.id, "demo-session-1")
        XCTAssertEqual(state.attachedSession?.stateText, "Running")
        XCTAssertEqual(state.fileReview.title, "File Review")
        XCTAssertTrue(state.fileReview.detail.contains("Changed files: 0"))
        XCTAssertEqual(state.auditTimeline.title, "Audit Timeline placeholder")

        let guardedStop = try XCTUnwrap(state.structuredActions.first { $0.id == "guarded-stop" })
        XCTAssertTrue(guardedStop.isAvailable)
        XCTAssertEqual(guardedStop.reason, "Demo session is running")
    }

    func testLoaderFetchesAndMapsForegroundState() async throws {
        let loader = ForegroundStateLoader(client: FakeForegroundStateClient(response: try DemoControlService().foregroundState()))

        let state = try await loader.load()

        XCTAssertEqual(state.activePlanningArtifact.title, "Scaffold Apple App Codebase with a demo Control API path")
        XCTAssertEqual(state.attachedSession?.summary, "Foreground Sync is connected to the seeded Mac Agent response.")
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
