import AgentShared
import MacAgentCore
import XCTest

final class DemoControlServiceTests: XCTestCase {
    func testForegroundStateReturnsSeededPlanningArtifactAndSession() throws {
        let response = try DemoControlService().foregroundState()

        XCTAssertEqual(response.planningArtifacts.count, 1)
        XCTAssertEqual(response.planningArtifacts.first?.id, "issue-2")
        XCTAssertEqual(response.planningArtifacts.first?.kind, .issue)
        XCTAssertNotNil(response.configuredRepository)
        XCTAssertEqual(response.activePlanningArtifactID, "issue-2")
        XCTAssertEqual(response.attachedSessions.count, 0)
        XCTAssertFalse(response.structuredActionAvailability.guardedStop.isAvailable)
        XCTAssertEqual(response.fileReview.status, .unavailable)
        XCTAssertEqual(response.auditTimeline.summary, "Audit Timeline")
        XCTAssertEqual(response.auditTimeline.entries.count, 0)
    }

    func testForegroundStateIncludesMacDeviceInfoFromStartupProvider() throws {
        let provider = FakeMacDeviceInfoProvider(
            info: MacDeviceInfo(
                name: "Development Mac",
                osVersion: "Version 14.5 (Build 23F79)",
                modelIdentifier: "Mac14,2"
            )
        )
        let service = DemoControlService(macDeviceInfoProvider: provider)

        let response = try service.foregroundState()

        XCTAssertEqual(response.macDeviceInfo?.name, "Development Mac")
        XCTAssertEqual(response.macDeviceInfo?.osVersion, "Version 14.5 (Build 23F79)")
        XCTAssertEqual(response.macDeviceInfo?.modelIdentifier, "Mac14,2")
        XCTAssertEqual(provider.callCount, 1)
    }

    func testForegroundStateJSONDecodesMacDeviceInfoFixture() throws {
        let data = Data("""
        {
          "configuredRepository": null,
          "macDeviceInfo": {
            "name": "Development Mac",
            "osVersion": "Version 14.5 (Build 23F79)",
            "modelIdentifier": "Mac14,2"
          },
          "planningArtifacts": [],
          "activePlanningArtifactID": null,
          "attachedSessions": [],
          "pendingInput": { "status": "unavailable" },
          "pendingApprovalRequest": null,
          "draftComment": {
            "id": "draft-comment-unavailable",
            "status": "unavailable",
            "title": "Draft Comment unavailable",
            "body": "",
            "preparedAt": null,
            "requiresApproval": false,
            "failureMessage": null
          },
          "structuredActionAvailability": {
            "reply": { "isAvailable": false, "reason": "No Pending Input", "requiresConfirmation": false },
            "approve": { "isAvailable": false, "reason": "No approval request", "requiresConfirmation": false },
            "deny": { "isAvailable": false, "reason": "No approval request", "requiresConfirmation": false },
            "draftComment": { "isAvailable": false, "reason": "No draft", "requiresConfirmation": false },
            "guardedStop": { "isAvailable": false, "reason": "No session", "requiresConfirmation": false }
          },
          "fileReview": {
            "status": "unavailable",
            "summary": "Unavailable",
            "changedFileCount": 0,
            "preExistingChangeCount": 0,
            "agentSessionChangeCount": 0,
            "files": []
          },
          "auditTimeline": {
            "summary": "Audit Timeline",
            "entries": []
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(ControlForegroundResponse.self, from: data)

        XCTAssertEqual(
            response.macDeviceInfo,
            MacDeviceInfo(
                name: "Development Mac",
                osVersion: "Version 14.5 (Build 23F79)",
                modelIdentifier: "Mac14,2"
            )
        )
    }

    func testForegroundStateJSONDecodesWhenMacDeviceInfoIsOmitted() throws {
        let data = Data("""
        {
          "configuredRepository": null,
          "planningArtifacts": [],
          "activePlanningArtifactID": null,
          "attachedSessions": [],
          "pendingInput": { "status": "unavailable" },
          "pendingApprovalRequest": null,
          "draftComment": {
            "id": "draft-comment-unavailable",
            "status": "unavailable",
            "title": "Draft Comment unavailable",
            "body": "",
            "preparedAt": null,
            "requiresApproval": false,
            "failureMessage": null
          },
          "structuredActionAvailability": {
            "reply": { "isAvailable": false, "reason": "No Pending Input", "requiresConfirmation": false },
            "approve": { "isAvailable": false, "reason": "No approval request", "requiresConfirmation": false },
            "deny": { "isAvailable": false, "reason": "No approval request", "requiresConfirmation": false },
            "draftComment": { "isAvailable": false, "reason": "No draft", "requiresConfirmation": false },
            "guardedStop": { "isAvailable": false, "reason": "No session", "requiresConfirmation": false }
          },
          "fileReview": {
            "status": "unavailable",
            "summary": "Unavailable",
            "changedFileCount": 0,
            "preExistingChangeCount": 0,
            "agentSessionChangeCount": 0,
            "files": []
          },
          "auditTimeline": {
            "summary": "Audit Timeline",
            "entries": []
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(ControlForegroundResponse.self, from: data)

        XCTAssertNil(response.macDeviceInfo)
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
        XCTAssertEqual(foregroundState.attachedSessions.count, 0)
    }

    func testLocalControlAPIExposesForegroundStateResponse() async throws {
        let server = LocalControlAPIServer(
            provider: DemoControlService(),
            securityPolicy: .unsecuredDemo,
            port: 0
        )
        let baseURL: URL
        do {
            baseURL = try server.start().url
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
        XCTAssertEqual(foregroundState.attachedSessions.count, 0)
    }
    #endif
}

private final class FakeMacDeviceInfoProvider: MacDeviceInfoProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let info: MacDeviceInfo
    private var count = 0

    init(info: MacDeviceInfo) {
        self.info = info
    }

    var callCount: Int {
        lock.withLock { count }
    }

    func macDeviceInfo() -> MacDeviceInfo {
        lock.withLock {
            count += 1
        }
        return info
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
