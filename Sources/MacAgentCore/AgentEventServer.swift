import Foundation
import Network

/// Loopback-only HTTP listener that receives Claude Code hook events POSTed by the
/// generated hook shim script running inside Wrapped Sessions.
///
/// This server is intentionally separate from `LocalControlAPIServer` — it uses plain
/// HTTP (no TLS) and a per-session bearer token rather than the paired Owner-Device
/// trust boundary. It binds exclusively to `127.0.0.1` and is never advertised on
/// the LAN.
public final class AgentEventServer: @unchecked Sendable {
    public static let eventsPath = "/v1/agent-events"

    public typealias EventHandler = @Sendable (ClaudeHookEvent) -> Void

    private let lock = NSAgentEventLock()
    private var nwListener: NWListener?
    // wrappedSessionID → (token, handler)
    private var sessions: [String: (token: String, handler: EventHandler)] = [:]
    private let decoder = JSONDecoder()
    private(set) public var port: UInt16 = 0

    public init() {}

    deinit { stop() }

    // MARK: - Lifecycle

    /// Starts listening on an OS-assigned loopback port. Returns the port number.
    @discardableResult
    public func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )

        let listener = try NWListener(using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var error: Error? }
        let box = Box()

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .waiting: semaphore.signal()
            case .failed(let err): box.error = err; semaphore.signal()
            default: break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .utility))
            self?.handleConnection(conn)
        }

        listener.start(queue: .global(qos: .utility))
        semaphore.wait()

        if let error = box.error {
            listener.cancel()
            throw error
        }

        let assignedPort = listener.port?.rawValue ?? 0
        lock.withLock {
            nwListener = listener
            port = assignedPort
        }
        return assignedPort
    }

    public func stop() {
        lock.withLock {
            nwListener?.cancel()
            nwListener = nil
        }
    }

    // MARK: - Session registration

    /// Register a session's bearer token and event handler. Called after launch.
    public func register(wrappedSessionID: String, token: String, handler: @escaping EventHandler) {
        lock.withLock { sessions[wrappedSessionID] = (token, handler) }
    }

    /// Remove a session's registration (e.g. after SessionEnd).
    public func unregister(wrappedSessionID: String) {
        lock.withLock { sessions.removeValue(forKey: wrappedSessionID) }
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let (statusCode, statusText) = self.process(data: data)
            let header = "HTTP/1.1 \(statusText)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // Returns (statusCode, statusText) and dispatches the event on success.
    @discardableResult
    private func process(data: Data) -> (Int, String) {
        let raw = String(decoding: data, as: UTF8.self)
        let req = ParsedLocalControlAPIRequest(rawRequest: raw)

        guard req.method == "POST", req.path == AgentEventServer.eventsPath else {
            return (404, "404 Not Found")
        }

        // Extract bearer token
        let authHeader = req.headers["authorization"] ?? ""
        guard authHeader.hasPrefix("Bearer ") else {
            return (401, "401 Unauthorized")
        }
        let token = String(authHeader.dropFirst("Bearer ".count))

        // Extract wrapped session id from custom header
        let wrappedSessionID = req.headers["x-wrapped-session-id"] ?? ""

        // Validate token and find handler
        let handler: EventHandler? = lock.withLock {
            if !wrappedSessionID.isEmpty,
               let entry = sessions[wrappedSessionID],
               entry.token == token
            {
                return entry.handler
            }
            // Token-only fallback (handles reconnect before re-registration)
            return sessions.values.first(where: { $0.token == token })?.handler
        }

        guard let handler else {
            return (401, "401 Unauthorized")
        }

        guard !req.body.isEmpty,
              let payload = try? decoder.decode(ClaudeHookPayload.self, from: req.body) else {
            return (400, "400 Bad Request")
        }

        let event = ClaudeHookEvent(
            wrappedSessionID: wrappedSessionID,
            payload: payload,
            rawBody: req.body,
            receivedAt: Date()
        )
        handler(event)
        return (200, "200 OK")
    }
}

// MARK: - Lock helper (named to avoid collision with LocalControlAPIServer's extension)

private final class NSAgentEventLock: @unchecked Sendable {
    private let underlying = NSLock()

    @discardableResult
    func withLock<Value>(_ body: () -> Value) -> Value {
        underlying.lock()
        defer { underlying.unlock() }
        return body()
    }
}
