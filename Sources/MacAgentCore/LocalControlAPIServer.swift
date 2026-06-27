#if os(macOS)
import AgentShared
import Darwin
import Foundation

public enum LocalControlAPIServerError: Error, Equatable {
    case socketCreationFailed
    case socketOptionFailed
    case bindFailed
    case listenFailed
    case portLookupFailed
}

public struct LocalControlAPIHTTPResponse: Equatable, Sendable {
    public var status: String
    public var statusCode: Int
    public var contentType: String
    public var body: Data

    public init(status: String, statusCode: Int, contentType: String, body: Data) {
        self.status = status
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

public struct LocalControlAPIResponder: Sendable {
    private let provider: any ControlAPIProviding
    private let encoder: JSONEncoder

    public init(provider: any ControlAPIProviding) {
        self.provider = provider
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func response(for request: String) -> LocalControlAPIHTTPResponse {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""

        if firstLine.hasPrefix("GET \(LocalControlAPIServer.foregroundStatePath) ") {
            return foregroundStateResponse()
        }

        return LocalControlAPIHTTPResponse(
            status: "404 Not Found",
            statusCode: 404,
            contentType: "text/plain; charset=utf-8",
            body: Data("Not Found".utf8)
        )
    }

    private func foregroundStateResponse() -> LocalControlAPIHTTPResponse {
        do {
            return LocalControlAPIHTTPResponse(
                status: "200 OK",
                statusCode: 200,
                contentType: "application/json",
                body: try encoder.encode(provider.foregroundState())
            )
        } catch {
            return LocalControlAPIHTTPResponse(
                status: "500 Internal Server Error",
                statusCode: 500,
                contentType: "application/json",
                body: Data("{\"error\":\"foreground_state_unavailable\"}".utf8)
            )
        }
    }
}

public final class LocalControlAPIServer: @unchecked Sendable {
    public static let foregroundStatePath = "/v1/foreground-state"

    private let responder: LocalControlAPIResponder
    private let requestedPort: UInt16
    private let lock = NSLock()
    private var socketFileDescriptor: Int32 = -1
    private var isStopping = false
    private var serverThread: Thread?

    public init(provider: any ControlAPIProviding, port: UInt16 = 5577) {
        self.responder = LocalControlAPIResponder(provider: provider)
        self.requestedPort = port
    }

    deinit {
        stop()
    }

    public func start() throws -> URL {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw LocalControlAPIServerError.socketCreationFailed
        }

        var reuseAddress: Int32 = 1
        let optionResult = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard optionResult == 0 else {
            close(fileDescriptor)
            throw LocalControlAPIServerError.socketOptionFailed
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                Darwin.bind(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fileDescriptor)
            throw LocalControlAPIServerError.bindFailed
        }

        guard listen(fileDescriptor, SOMAXCONN) == 0 else {
            close(fileDescriptor)
            throw LocalControlAPIServerError.listenFailed
        }

        let port = try boundPort(for: fileDescriptor)
        lock.withLock {
            socketFileDescriptor = fileDescriptor
            isStopping = false
        }

        let thread = Thread { [weak self] in
            self?.serveRequests(from: fileDescriptor)
        }
        thread.name = "LocalControlAPIServer"
        serverThread = thread
        thread.start()

        return URL(string: "http://127.0.0.1:\(port)")!
    }

    public func stop() {
        let fileDescriptor = lock.withLock {
            isStopping = true
            let current = socketFileDescriptor
            socketFileDescriptor = -1
            return current
        }

        if fileDescriptor >= 0 {
            shutdown(fileDescriptor, SHUT_RDWR)
            close(fileDescriptor)
        }
    }

    private func serveRequests(from fileDescriptor: Int32) {
        while shouldContinueServing {
            var clientAddress = sockaddr()
            var clientAddressLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fileDescriptor, &clientAddress, &clientAddressLength)

            guard client >= 0 else {
                continue
            }

            handleConnection(client)
            close(client)
        }
    }

    private var shouldContinueServing: Bool {
        lock.withLock { !isStopping }
    }

    private func handleConnection(_ fileDescriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let byteCount = read(fileDescriptor, &buffer, buffer.count)
        guard byteCount > 0 else {
            return
        }

        let response = responder.response(for: String(decoding: buffer.prefix(byteCount), as: UTF8.self))
        writeResponse(response, to: fileDescriptor)
    }

    private func writeResponse(_ httpResponse: LocalControlAPIHTTPResponse, to fileDescriptor: Int32) {
        let header = """
        HTTP/1.1 \(httpResponse.status)\r
        Content-Type: \(httpResponse.contentType)\r
        Content-Length: \(httpResponse.body.count)\r
        Connection: close\r
        \r

        """

        var response = Data(header.utf8)
        response.append(httpResponse.body)
        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            _ = Darwin.write(fileDescriptor, baseAddress, response.count)
        }
    }

    private func boundPort(for fileDescriptor: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                getsockname(fileDescriptor, reboundPointer, &length)
            }
        }

        guard result == 0 else {
            throw LocalControlAPIServerError.portLookupFailed
        }

        return UInt16(bigEndian: address.sin_port)
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}
#endif
