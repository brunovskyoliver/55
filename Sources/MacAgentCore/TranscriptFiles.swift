import AgentShared
import Foundation

public protocol TranscriptMetadataStoring: Sendable {
    func appendTranscriptMetadata(_ record: TranscriptFileRecord) throws
    func queryTranscriptMetadata(_ query: TranscriptFileQuery) throws -> [TranscriptFileRecord]
}

public protocol TranscriptFileRecording: Sendable {
    func append(_ request: TranscriptAppendRequest) throws -> TranscriptFileRecord
}

public protocol WrappedSessionTranscriptCapturing: Sendable {
    func captureTranscriptChunk(
        for session: AttachedSession,
        planningArtifact: PlanningArtifact
    ) throws -> TranscriptFileRecord?
}

public struct DisabledWrappedSessionTranscriptCapturer: WrappedSessionTranscriptCapturing {
    public init() {}

    public func captureTranscriptChunk(
        for session: AttachedSession,
        planningArtifact: PlanningArtifact
    ) throws -> TranscriptFileRecord? {
        nil
    }
}

public struct TranscriptAppendRequest: Equatable, Sendable {
    public var planningArtifactID: PlanningArtifact.ID
    public var agentSessionID: AgentSession.ID
    public var chunk: Data
    public var capturedAt: Date

    public init(
        planningArtifactID: PlanningArtifact.ID,
        agentSessionID: AgentSession.ID,
        chunk: Data,
        capturedAt: Date
    ) {
        self.planningArtifactID = planningArtifactID
        self.agentSessionID = agentSessionID
        self.chunk = chunk
        self.capturedAt = capturedAt
    }
}

public struct TranscriptFileQuery: Equatable, Sendable {
    public var planningArtifactID: PlanningArtifact.ID?
    public var agentSessionID: AgentSession.ID?
    public var limit: Int?

    public init(
        planningArtifactID: PlanningArtifact.ID? = nil,
        agentSessionID: AgentSession.ID? = nil,
        limit: Int? = nil
    ) {
        self.planningArtifactID = planningArtifactID
        self.agentSessionID = agentSessionID
        self.limit = limit
    }
}

public struct TranscriptFileRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var planningArtifactID: PlanningArtifact.ID
    public var agentSessionID: AgentSession.ID
    public var relativePath: String
    public var byteOffsetStart: Int64
    public var byteOffsetEnd: Int64
    public var byteCount: Int64
    public var capturedAt: Date

    public init(
        id: String,
        planningArtifactID: PlanningArtifact.ID,
        agentSessionID: AgentSession.ID,
        relativePath: String,
        byteOffsetStart: Int64,
        byteOffsetEnd: Int64,
        byteCount: Int64,
        capturedAt: Date
    ) {
        self.id = id
        self.planningArtifactID = planningArtifactID
        self.agentSessionID = agentSessionID
        self.relativePath = relativePath
        self.byteOffsetStart = byteOffsetStart
        self.byteOffsetEnd = byteOffsetEnd
        self.byteCount = byteCount
        self.capturedAt = capturedAt
    }
}

public enum TranscriptFileError: Error, Equatable, Sendable {
    case emptyChunk
    case missingTmuxAttachment
    case captureFailed(String)
    case fileAppendFailed(String)

    var userMessage: String {
        switch self {
        case .emptyChunk:
            return "The transcript chunk was empty."
        case .missingTmuxAttachment:
            return "The active Wrapped Session has no tmux attachment for transcript capture."
        case .captureFailed(let detail):
            return detail.isEmpty ? "The Mac Agent could not capture tmux transcript output." : detail
        case .fileAppendFailed(let detail):
            return detail.isEmpty ? "The Mac Agent could not append the transcript file." : detail
        }
    }
}

public final class LocalTranscriptFileStore: TranscriptFileRecording, @unchecked Sendable {
    private let rootDirectory: URL
    private let metadataStore: any TranscriptMetadataStoring
    private let recordIDGenerator: @Sendable () -> String
    private let lock = NSLock()

    public init(
        rootDirectory: URL,
        metadataStore: any TranscriptMetadataStoring,
        recordIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.rootDirectory = rootDirectory
        self.metadataStore = metadataStore
        self.recordIDGenerator = recordIDGenerator
    }

    public static func applicationSupportStore(
        metadataStore: any TranscriptMetadataStoring = SQLiteSessionStore.applicationSupportStore()
    ) -> LocalTranscriptFileStore {
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/AgentSessionControl", directoryHint: .isDirectory)
        return LocalTranscriptFileStore(
            rootDirectory: directory.appending(path: "Transcripts", directoryHint: .isDirectory),
            metadataStore: metadataStore
        )
    }

    public func append(_ request: TranscriptAppendRequest) throws -> TranscriptFileRecord {
        try lock.withLock {
            guard !request.chunk.isEmpty else {
                throw TranscriptFileError.emptyChunk
            }

            let relativePath = "\(fileStem(planningArtifactID: request.planningArtifactID, agentSessionID: request.agentSessionID)).raw.log"
            let fileURL = rootDirectory.appending(path: relativePath)

            do {
                try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: fileURL)
                defer {
                    try? handle.close()
                }
                let startOffset = try Int64(handle.seekToEnd())
                try handle.write(contentsOf: request.chunk)
                let endOffset = startOffset + Int64(request.chunk.count)
                let record = TranscriptFileRecord(
                    id: recordIDGenerator(),
                    planningArtifactID: request.planningArtifactID,
                    agentSessionID: request.agentSessionID,
                    relativePath: relativePath,
                    byteOffsetStart: startOffset,
                    byteOffsetEnd: endOffset,
                    byteCount: Int64(request.chunk.count),
                    capturedAt: request.capturedAt
                )
                try metadataStore.appendTranscriptMetadata(record)
                return record
            } catch let error as TranscriptFileError {
                throw error
            } catch {
                throw TranscriptFileError.fileAppendFailed(String(describing: error))
            }
        }
    }

    private func fileStem(planningArtifactID: String, agentSessionID: String) -> String {
        "\(sanitizedPathComponent(planningArtifactID))-\(sanitizedPathComponent(agentSessionID))"
    }

    private func sanitizedPathComponent(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = String(rawValue.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}

public struct TmuxWrappedSessionTranscriptCapturer: WrappedSessionTranscriptCapturing {
    private let executor: any ProcessCommandExecuting
    private let transcriptStore: any TranscriptFileRecording
    private let now: @Sendable () -> Date

    public init(
        executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor(),
        transcriptStore: any TranscriptFileRecording = LocalTranscriptFileStore.applicationSupportStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.executor = executor
        self.transcriptStore = transcriptStore
        self.now = now
    }

    public func captureTranscriptChunk(
        for session: AttachedSession,
        planningArtifact: PlanningArtifact
    ) throws -> TranscriptFileRecord? {
        guard let tmuxAttachment = session.session.tmuxAttachment else {
            throw TranscriptFileError.missingTmuxAttachment
        }

        do {
            let result = try executor.run(
                executable: "tmux",
                arguments: ["capture-pane", "-p", "-S", "-", "-t", tmuxAttachment.sessionName]
            )
            guard !result.stdout.isEmpty else {
                return nil
            }
            return try transcriptStore.append(
                TranscriptAppendRequest(
                    planningArtifactID: planningArtifact.id,
                    agentSessionID: session.session.id,
                    chunk: result.stdout,
                    capturedAt: now()
                )
            )
        } catch let error as TranscriptFileError {
            throw error
        } catch let error as ProcessCommandFailure {
            throw TranscriptFileError.captureFailed(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw TranscriptFileError.captureFailed(String(describing: error))
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
