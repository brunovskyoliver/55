import AgentShared
import MacAgentCore
import XCTest

final class DemoControlServiceTests: XCTestCase {
    func testForegroundStateReturnsSeededPlanningArtifactAndSession() throws {
        let response = try DemoControlService().foregroundState()

        XCTAssertEqual(response.planningArtifacts.count, 1)
        XCTAssertEqual(response.planningArtifacts.first?.id, "issue-2")
        XCTAssertEqual(response.planningArtifacts.first?.kind, .issue)
        XCTAssertEqual(response.activePlanningArtifactID, "issue-2")
        XCTAssertEqual(response.attachedSessions.first?.session.state, .running)
        XCTAssertTrue(response.structuredActionAvailability.guardedStop.isAvailable)
        XCTAssertEqual(response.fileReview.status, "placeholder")
        XCTAssertEqual(response.auditTimeline.entries.count, 1)
    }

    #if os(macOS)
    func testLocalControlAPIResponderBuildsForegroundStateResponse() throws {
        let responder = LocalControlAPIResponder(
            provider: DemoControlService(),
            securityPolicy: .unsecuredDemo
        )

        let httpResponse = responder.response(for: "GET /v1/foreground-state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.contentType, "application/json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let foregroundState = try decoder.decode(ControlForegroundResponse.self, from: httpResponse.body)

        XCTAssertEqual(foregroundState.activePlanningArtifactID, "issue-2")
        XCTAssertEqual(foregroundState.attachedSessions.first?.session.displayName, "Demo Agent Session")
    }

    func testLocalControlAPIExposesForegroundStateResponse() async throws {
        let server = LocalControlAPIServer(
            provider: DemoControlService(),
            securityPolicy: .unsecuredDemo,
            port: 0
        )
        let baseURL: URL
        do {
            baseURL = try server.start()
        } catch LocalControlAPIServerError.bindFailed {
            throw XCTSkip("The execution sandbox denied binding a local socket.")
        }
        defer {
            server.stop()
        }

        let url = baseURL.appending(path: "v1/foreground-state")
        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let foregroundState = try decoder.decode(ControlForegroundResponse.self, from: data)

        XCTAssertEqual(foregroundState.activePlanningArtifactID, "issue-2")
        XCTAssertEqual(foregroundState.attachedSessions.first?.session.displayName, "Demo Agent Session")
    }
    #endif
}
