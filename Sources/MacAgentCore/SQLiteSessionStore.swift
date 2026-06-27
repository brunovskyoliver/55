import AgentShared
import Foundation
import SQLite3

public protocol SessionEventStoring: Sendable {
    func append(_ event: SessionEventLogEntry) throws
    func query(_ query: SessionEventQuery) throws -> [SessionEventLogEntry]
}

public struct SessionEventQuery: Equatable, Sendable {
    public var planningArtifactID: PlanningArtifact.ID?
    public var agentSessionID: AgentSession.ID?
    public var eventTypes: [SessionEventType]
    public var limit: Int?

    public init(
        planningArtifactID: PlanningArtifact.ID? = nil,
        agentSessionID: AgentSession.ID? = nil,
        eventTypes: [SessionEventType] = [],
        limit: Int? = nil
    ) {
        self.planningArtifactID = planningArtifactID
        self.agentSessionID = agentSessionID
        self.eventTypes = eventTypes
        self.limit = limit
    }
}

public enum SessionStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case schemaFailed(String)
    case statementFailed(String)
    case executionFailed(String)
    case invalidStoredEvent(String)
}

public final class SQLiteSessionStore: SessionEventStoring, TranscriptMetadataStoring, @unchecked Sendable {
    private let databaseURL: URL
    private let lock = NSLock()
    private let metadataEncoder = JSONEncoder()
    private let metadataDecoder = JSONDecoder()

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public static func inMemory() -> SQLiteSessionStore {
        SQLiteSessionStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appending(path: "AgentSessionControl-\(UUID().uuidString).sqlite")
        )
    }

    public static func applicationSupportStore() -> SQLiteSessionStore {
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/AgentSessionControl", directoryHint: .isDirectory)
        return SQLiteSessionStore(databaseURL: directory.appending(path: "session-store.sqlite"))
    }

    public func append(_ event: SessionEventLogEntry) throws {
        try lock.withLock {
            let database = try openDatabase()
            defer { sqlite3_close(database) }

            let storedEvent = sanitized(event)
            let metadataData = try metadataEncoder.encode(storedEvent.metadata)
            let metadataJSON = String(decoding: metadataData, as: UTF8.self)

            let sql = """
            INSERT INTO session_events (
                id,
                planning_artifact_id,
                agent_session_id,
                event_type,
                title,
                detail,
                occurred_at,
                metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            let statement = try prepare(sql, database: database)
            defer { sqlite3_finalize(statement) }

            bindText(storedEvent.id, at: 1, in: statement)
            bindText(storedEvent.planningArtifactID, at: 2, in: statement)
            bindNullableText(storedEvent.agentSessionID, at: 3, in: statement)
            bindText(storedEvent.eventType.rawValue, at: 4, in: statement)
            bindText(storedEvent.title, at: 5, in: statement)
            bindText(storedEvent.detail, at: 6, in: statement)
            sqlite3_bind_double(statement, 7, storedEvent.occurredAt.timeIntervalSince1970)
            bindText(metadataJSON, at: 8, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionStoreError.executionFailed(lastErrorMessage(database))
            }
        }
    }

    public func query(_ query: SessionEventQuery = SessionEventQuery()) throws -> [SessionEventLogEntry] {
        try lock.withLock {
            let database = try openDatabase()
            defer { sqlite3_close(database) }

            var clauses: [String] = []
            var textBindings: [String] = []

            if let planningArtifactID = query.planningArtifactID {
                clauses.append("planning_artifact_id = ?")
                textBindings.append(planningArtifactID)
            }

            if let agentSessionID = query.agentSessionID {
                clauses.append("agent_session_id = ?")
                textBindings.append(agentSessionID)
            }

            if !query.eventTypes.isEmpty {
                clauses.append("event_type IN (\(Array(repeating: "?", count: query.eventTypes.count).joined(separator: ", ")))")
                textBindings.append(contentsOf: query.eventTypes.map(\.rawValue))
            }

            var sql = """
            SELECT id, planning_artifact_id, agent_session_id, event_type, title, detail, occurred_at, metadata_json
            FROM session_events
            """
            if !clauses.isEmpty {
                sql += " WHERE \(clauses.joined(separator: " AND "))"
            }
            sql += " ORDER BY occurred_at ASC, sequence ASC"
            if let limit = query.limit {
                sql += " LIMIT \(max(0, limit))"
            }

            let statement = try prepare(sql, database: database)
            defer { sqlite3_finalize(statement) }

            for (index, value) in textBindings.enumerated() {
                bindText(value, at: Int32(index + 1), in: statement)
            }

            var events: [SessionEventLogEntry] = []
            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_DONE {
                    break
                }
                guard stepResult == SQLITE_ROW else {
                    throw SessionStoreError.executionFailed(lastErrorMessage(database))
                }
                events.append(try event(from: statement))
            }
            return events
        }
    }

    public func appendTranscriptMetadata(_ record: TranscriptFileRecord) throws {
        try lock.withLock {
            let database = try openDatabase()
            defer { sqlite3_close(database) }

            let sql = """
            INSERT INTO transcript_files (
                id,
                planning_artifact_id,
                agent_session_id,
                relative_path,
                byte_offset_start,
                byte_offset_end,
                byte_count,
                captured_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            let statement = try prepare(sql, database: database)
            defer { sqlite3_finalize(statement) }

            bindText(record.id, at: 1, in: statement)
            bindText(record.planningArtifactID, at: 2, in: statement)
            bindText(record.agentSessionID, at: 3, in: statement)
            bindText(record.relativePath, at: 4, in: statement)
            sqlite3_bind_int64(statement, 5, record.byteOffsetStart)
            sqlite3_bind_int64(statement, 6, record.byteOffsetEnd)
            sqlite3_bind_int64(statement, 7, record.byteCount)
            sqlite3_bind_double(statement, 8, record.capturedAt.timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionStoreError.executionFailed(lastErrorMessage(database))
            }
        }
    }

    public func queryTranscriptMetadata(_ query: TranscriptFileQuery = TranscriptFileQuery()) throws -> [TranscriptFileRecord] {
        try lock.withLock {
            let database = try openDatabase()
            defer { sqlite3_close(database) }

            var clauses: [String] = []
            var textBindings: [String] = []

            if let planningArtifactID = query.planningArtifactID {
                clauses.append("planning_artifact_id = ?")
                textBindings.append(planningArtifactID)
            }

            if let agentSessionID = query.agentSessionID {
                clauses.append("agent_session_id = ?")
                textBindings.append(agentSessionID)
            }

            var sql = """
            SELECT id, planning_artifact_id, agent_session_id, relative_path, byte_offset_start, byte_offset_end, byte_count, captured_at
            FROM transcript_files
            """
            if !clauses.isEmpty {
                sql += " WHERE \(clauses.joined(separator: " AND "))"
            }
            sql += " ORDER BY captured_at ASC, sequence ASC"
            if let limit = query.limit {
                sql += " LIMIT \(max(0, limit))"
            }

            let statement = try prepare(sql, database: database)
            defer { sqlite3_finalize(statement) }

            for (index, value) in textBindings.enumerated() {
                bindText(value, at: Int32(index + 1), in: statement)
            }

            var records: [TranscriptFileRecord] = []
            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_DONE {
                    break
                }
                guard stepResult == SQLITE_ROW else {
                    throw SessionStoreError.executionFailed(lastErrorMessage(database))
                }
                records.append(try transcriptRecord(from: statement))
            }
            return records
        }
    }

    private func openDatabase() throws -> OpaquePointer? {
        if databaseURL.path != ":memory:" {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.map(lastErrorMessage) ?? "SQLite did not return a database handle."
            if let database {
                sqlite3_close(database)
            }
            throw SessionStoreError.openFailed(message)
        }

        do {
            try ensureSchema(database)
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private func ensureSchema(_ database: OpaquePointer?) throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS session_events (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            planning_artifact_id TEXT NOT NULL,
            agent_session_id TEXT,
            event_type TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL,
            occurred_at REAL NOT NULL,
            metadata_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_session_events_artifact_time
            ON session_events(planning_artifact_id, occurred_at, sequence);
        CREATE INDEX IF NOT EXISTS idx_session_events_session_time
            ON session_events(agent_session_id, occurred_at, sequence);
        CREATE INDEX IF NOT EXISTS idx_session_events_type_time
            ON session_events(event_type, occurred_at, sequence);
        CREATE TABLE IF NOT EXISTS transcript_files (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            planning_artifact_id TEXT NOT NULL,
            agent_session_id TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            byte_offset_start INTEGER NOT NULL,
            byte_offset_end INTEGER NOT NULL,
            byte_count INTEGER NOT NULL,
            captured_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_transcript_files_session_time
            ON transcript_files(planning_artifact_id, agent_session_id, captured_at, sequence);
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw SessionStoreError.schemaFailed(lastErrorMessage(database))
        }
    }

    private func prepare(_ sql: String, database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionStoreError.statementFailed(lastErrorMessage(database))
        }
        return statement
    }

    private func bindText(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindNullableText(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            bindText(value, at: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func event(from statement: OpaquePointer?) throws -> SessionEventLogEntry {
        let typeRawValue = try stringColumn(3, in: statement)
        guard let eventType = SessionEventType(rawValue: typeRawValue) else {
            throw SessionStoreError.invalidStoredEvent("Unknown event type: \(typeRawValue)")
        }

        let metadataJSON = try stringColumn(7, in: statement)
        let metadata = try metadataDecoder.decode([String: String].self, from: Data(metadataJSON.utf8))

        return SessionEventLogEntry(
            id: try stringColumn(0, in: statement),
            planningArtifactID: try stringColumn(1, in: statement),
            agentSessionID: nullableStringColumn(2, in: statement),
            eventType: eventType,
            title: try stringColumn(4, in: statement),
            detail: try stringColumn(5, in: statement),
            occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            metadata: metadata
        )
    }

    private func transcriptRecord(from statement: OpaquePointer?) throws -> TranscriptFileRecord {
        TranscriptFileRecord(
            id: try stringColumn(0, in: statement),
            planningArtifactID: try stringColumn(1, in: statement),
            agentSessionID: try stringColumn(2, in: statement),
            relativePath: try stringColumn(3, in: statement),
            byteOffsetStart: sqlite3_column_int64(statement, 4),
            byteOffsetEnd: sqlite3_column_int64(statement, 5),
            byteCount: sqlite3_column_int64(statement, 6),
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        )
    }

    private func stringColumn(_ index: Int32, in statement: OpaquePointer?) throws -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            throw SessionStoreError.invalidStoredEvent("Column \(index) was not text.")
        }
        return String(cString: text)
    }

    private func nullableStringColumn(_ index: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func sanitized(_ event: SessionEventLogEntry) -> SessionEventLogEntry {
        var event = event
        let secretValues = event.metadata.compactMap { key, value -> String? in
            Self.secretLikeMetadataKey(key) ? value : nil
        }
        for secretValue in secretValues where !secretValue.isEmpty {
            event.title = event.title.replacingOccurrences(of: secretValue, with: "[redacted]")
            event.detail = event.detail.replacingOccurrences(of: secretValue, with: "[redacted]")
        }
        event.metadata = event.metadata.filter { key, _ in
            !Self.secretLikeMetadataKey(key)
        }
        return event
    }

    private static func secretLikeMetadataKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.contains("secret")
            || normalized.contains("token")
            || normalized.contains("credential")
            || normalized.contains("password")
            || normalized.contains("privatekey")
            || normalized.contains("apikey")
            || normalized.contains("authorization")
    }

    private func lastErrorMessage(_ database: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(database) else {
            return "Unknown SQLite error."
        }
        return String(cString: message)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
