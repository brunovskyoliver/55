import AgentShared
import MacAgentCore
import XCTest

final class SessionEventStoreTests: XCTestCase {
    func testAppendAndOrderedTimelineQuery() throws {
        let store = try temporaryStore()

        try store.append(event(id: "second", occurredAt: Date(timeIntervalSince1970: 20)))
        try store.append(event(id: "first", occurredAt: Date(timeIntervalSince1970: 10)))

        let events = try store.query(SessionEventQuery(planningArtifactID: "issue-6"))

        XCTAssertEqual(events.map(\.id), ["first", "second"])
    }

    func testQueryFiltersByPlanningArtifactSessionAndEventType() throws {
        let store = try temporaryStore()
        try store.append(event(id: "matching", agentSessionID: "session-1", eventType: .structuredActionResult))
        try store.append(event(id: "wrong-artifact", planningArtifactID: "issue-7", agentSessionID: "session-1", eventType: .structuredActionResult))
        try store.append(event(id: "wrong-session", agentSessionID: "session-2", eventType: .structuredActionResult))
        try store.append(event(id: "wrong-type", agentSessionID: "session-1", eventType: .sessionLifecycle))

        let events = try store.query(
            SessionEventQuery(
                planningArtifactID: "issue-6",
                agentSessionID: "session-1",
                eventTypes: [.structuredActionResult]
            )
        )

        XCTAssertEqual(events.map(\.id), ["matching"])
    }

    func testEventsPersistAcrossStoreRestart() throws {
        let databaseURL = try temporaryDatabaseURL()
        let firstStore = SQLiteSessionStore(databaseURL: databaseURL)
        try firstStore.append(event(id: "persisted"))

        let restartedStore = SQLiteSessionStore(databaseURL: databaseURL)
        let events = try restartedStore.query(SessionEventQuery(planningArtifactID: "issue-6"))

        XCTAssertEqual(events.map(\.id), ["persisted"])
    }

    func testSecretLikeMetadataIsExcludedFromStoredEvents() throws {
        let store = try temporaryStore()
        try store.append(
            SessionEventLogEntry(
                id: "redacted",
                planningArtifactID: "issue-6",
                eventType: .structuredActionAttempt,
                title: "Used api token should-not-be-stored",
                detail: "Pairing secret should-not-be-stored is unavailable.",
                occurredAt: Date(timeIntervalSince1970: 10),
                metadata: [
                    "publicSummary": "visible",
                    "apiToken": "should-not-be-stored",
                    "pairingSecret": "should-not-be-stored",
                    "ownerCredential": "should-not-be-stored",
                    "authorization": "Bearer should-not-be-stored"
                ]
            )
        )

        let stored = try XCTUnwrap(store.query(SessionEventQuery(planningArtifactID: "issue-6")).first)

        XCTAssertEqual(stored.metadata, ["publicSummary": "visible"])
        XCTAssertFalse(String(describing: stored).contains("should-not-be-stored"))
        XCTAssertTrue(stored.title.contains("[redacted]"))
        XCTAssertTrue(stored.detail.contains("[redacted]"))
    }
}

private func temporaryStore() throws -> SQLiteSessionStore {
    SQLiteSessionStore(databaseURL: try temporaryDatabaseURL())
}

private func temporaryDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "AgentSessionControlTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "session-store.sqlite")
}

private func event(
    id: String,
    planningArtifactID: PlanningArtifact.ID = "issue-6",
    agentSessionID: AgentSession.ID? = nil,
    eventType: SessionEventType = .planningArtifactAttached,
    occurredAt: Date = Date(timeIntervalSince1970: 10),
    metadata: [String: String] = [:]
) -> SessionEventLogEntry {
    SessionEventLogEntry(
        id: id,
        planningArtifactID: planningArtifactID,
        agentSessionID: agentSessionID,
        eventType: eventType,
        title: "Event \(id)",
        detail: "Detail \(id)",
        occurredAt: occurredAt,
        metadata: metadata
    )
}
