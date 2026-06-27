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
    private let artifactAttacher: (any PlanningArtifactAttaching)?
    private let sessionStarter: (any WrappedSessionStarting)?
    private let pendingInputReplySubmitter: (any PendingInputReplySubmitting)?
    private let approvalDecisionSubmitter: (any ApprovalDecisionSubmitting)?
    private let draftCommentPreparer: (any DraftCommentPreparing)?
    private let draftCommentDecisionSubmitter: (any DraftCommentDecisionSubmitting)?
    private let pairingService: MacPairingService?
    private let securityPolicy: ControlAPISecurityPolicy
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        provider: any ControlAPIProviding,
        pairingService: MacPairingService? = nil,
        securityPolicy: ControlAPISecurityPolicy
    ) {
        self.provider = provider
        self.artifactAttacher = provider as? any PlanningArtifactAttaching
        self.sessionStarter = provider as? any WrappedSessionStarting
        self.pendingInputReplySubmitter = provider as? any PendingInputReplySubmitting
        self.approvalDecisionSubmitter = provider as? any ApprovalDecisionSubmitting
        self.draftCommentPreparer = provider as? any DraftCommentPreparing
        self.draftCommentDecisionSubmitter = provider as? any DraftCommentDecisionSubmitting
        self.pairingService = pairingService
        self.securityPolicy = securityPolicy
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func response(
        for rawRequest: String,
        channelSecurity: ControlAPIChannelSecurity = .plainHTTP
    ) -> LocalControlAPIHTTPResponse {
        let request = ParsedLocalControlAPIRequest(rawRequest: rawRequest)

        if request.method == "GET", request.path == LocalControlAPIServer.foregroundStatePath {
            let authorization = securityPolicy.authorize(request: request, channelSecurity: channelSecurity)
            guard case .authorized = authorization else {
                return authorizationFailureResponse(authorization)
            }

            return foregroundStateResponse()
        }

        if request.method == "POST", request.path == LocalControlAPIServer.planningArtifactAttachmentPath {
            let authorization = securityPolicy.authorize(request: request, channelSecurity: channelSecurity)
            guard case .authorized = authorization else {
                return authorizationFailureResponse(authorization)
            }

            return planningArtifactAttachmentResponse(body: request.body)
        }

        if request.method == "POST", request.path == LocalControlAPIServer.wrappedSessionStartPath {
            let authorization = securityPolicy.authorize(request: request, channelSecurity: channelSecurity)
            guard case .authorized = authorization else {
                return authorizationFailureResponse(authorization)
            }

            return wrappedSessionStartResponse(body: request.body)
        }

        if request.method == "POST", request.path == LocalControlAPIServer.pendingInputReplyPath {
            let authorization = securityPolicy.authorize(request: request, channelSecurity: channelSecurity)
            guard case .authorized = authorization else {
                return authorizationFailureResponse(authorization)
            }

            return pendingInputReplyResponse(body: request.body)
        }

        if request.method == "POST", request.path == LocalControlAPIServer.approvalDecisionPath {
            let authorization = securityPolicy.authorize(request: request, channelSecurity: channelSecurity)
            guard case .authorized = authorization else {
                return authorizationFailureResponse(authorization)
            }

            return approvalDecisionResponse(body: request.body)
        }

        if request.method == "POST", request.path == LocalControlAPIServer.draftCommentPreparePath {
            let authorization = securityPolicy.authorize(request: request, channelSecurity: channelSecurity)
            guard case .authorized = authorization else {
                return authorizationFailureResponse(authorization)
            }

            return draftCommentPrepareResponse(body: request.body)
        }

        if request.method == "POST", request.path == LocalControlAPIServer.draftCommentDecisionPath {
            let authorization = securityPolicy.authorize(request: request, channelSecurity: channelSecurity)
            guard case .authorized = authorization else {
                return authorizationFailureResponse(authorization)
            }

            return draftCommentDecisionResponse(body: request.body)
        }

        if request.method == "POST", request.path == LocalControlAPIServer.pairingCompletionPath {
            let authorization = securityPolicy.authorizePairingCompletion(channelSecurity: channelSecurity)
            guard case .authorized = authorization else {
                return authorizationFailureResponse(authorization)
            }

            return pairingCompletionResponse(body: request.body)
        }

        return LocalControlAPIHTTPResponse(
            status: "404 Not Found",
            statusCode: 404,
            contentType: "text/plain; charset=utf-8",
            body: Data("Not Found".utf8)
        )
    }

    private func pendingInputReplyResponse(body: Data) -> LocalControlAPIHTTPResponse {
        guard let pendingInputReplySubmitter else {
            return jsonErrorResponse(
                status: "503 Service Unavailable",
                statusCode: 503,
                errorCode: "pending_input_reply_unavailable",
                message: "This Mac Agent cannot submit Pending Input replies."
            )
        }

        do {
            let request = try decoder.decode(SubmitPendingInputReplyRequest.self, from: body)
            return LocalControlAPIHTTPResponse(
                status: "200 OK",
                statusCode: 200,
                contentType: "application/json",
                body: try encoder.encode(pendingInputReplySubmitter.submitPendingInputReply(request))
            )
        } catch let error as PendingInputReplyError {
            return jsonErrorResponse(
                status: pendingInputReplyFailureStatus(for: error),
                statusCode: pendingInputReplyFailureStatusCode(for: error),
                errorCode: error.apiErrorCode,
                message: error.userMessage
            )
        } catch {
            return jsonErrorResponse(
                status: "400 Bad Request",
                statusCode: 400,
                errorCode: "pending_input_reply_failed",
                message: "The Pending Input reply request could not be completed."
            )
        }
    }

    private func approvalDecisionResponse(body: Data) -> LocalControlAPIHTTPResponse {
        guard let approvalDecisionSubmitter else {
            return jsonErrorResponse(
                status: "503 Service Unavailable",
                statusCode: 503,
                errorCode: "approval_decision_unavailable",
                message: "This Mac Agent cannot submit approval decisions."
            )
        }

        do {
            let request = try decoder.decode(SubmitApprovalDecisionRequest.self, from: body)
            return LocalControlAPIHTTPResponse(
                status: "200 OK",
                statusCode: 200,
                contentType: "application/json",
                body: try encoder.encode(approvalDecisionSubmitter.submitApprovalDecision(request))
            )
        } catch let error as ApprovalDecisionError {
            return jsonErrorResponse(
                status: approvalDecisionFailureStatus(for: error),
                statusCode: approvalDecisionFailureStatusCode(for: error),
                errorCode: error.apiErrorCode,
                message: error.userMessage
            )
        } catch {
            return jsonErrorResponse(
                status: "400 Bad Request",
                statusCode: 400,
                errorCode: "approval_decision_failed",
                message: "The approval decision request could not be completed."
            )
        }
    }

    private func draftCommentPrepareResponse(body: Data) -> LocalControlAPIHTTPResponse {
        guard let draftCommentPreparer else {
            return jsonErrorResponse(
                status: "503 Service Unavailable",
                statusCode: 503,
                errorCode: "draft_comment_unavailable",
                message: "This Mac Agent cannot prepare Draft Comments."
            )
        }

        do {
            let request = body.isEmpty
                ? PrepareDraftCommentRequest()
                : try decoder.decode(PrepareDraftCommentRequest.self, from: body)
            return LocalControlAPIHTTPResponse(
                status: "200 OK",
                statusCode: 200,
                contentType: "application/json",
                body: try encoder.encode(draftCommentPreparer.prepareDraftComment(request))
            )
        } catch let error as DraftCommentError {
            return jsonErrorResponse(
                status: draftCommentFailureStatus(for: error),
                statusCode: draftCommentFailureStatusCode(for: error),
                errorCode: error.apiErrorCode,
                message: error.userMessage
            )
        } catch {
            return jsonErrorResponse(
                status: "400 Bad Request",
                statusCode: 400,
                errorCode: "draft_comment_prepare_failed",
                message: "The Draft Comment could not be prepared."
            )
        }
    }

    private func draftCommentDecisionResponse(body: Data) -> LocalControlAPIHTTPResponse {
        guard let draftCommentDecisionSubmitter else {
            return jsonErrorResponse(
                status: "503 Service Unavailable",
                statusCode: 503,
                errorCode: "draft_comment_unavailable",
                message: "This Mac Agent cannot decide Draft Comments."
            )
        }

        do {
            let request = try decoder.decode(SubmitDraftCommentDecisionRequest.self, from: body)
            return LocalControlAPIHTTPResponse(
                status: "200 OK",
                statusCode: 200,
                contentType: "application/json",
                body: try encoder.encode(draftCommentDecisionSubmitter.submitDraftCommentDecision(request))
            )
        } catch let error as DraftCommentError {
            return jsonErrorResponse(
                status: draftCommentFailureStatus(for: error),
                statusCode: draftCommentFailureStatusCode(for: error),
                errorCode: error.apiErrorCode,
                message: error.userMessage
            )
        } catch {
            return jsonErrorResponse(
                status: "400 Bad Request",
                statusCode: 400,
                errorCode: "draft_comment_decision_failed",
                message: "The Draft Comment decision could not be completed."
            )
        }
    }

    private func wrappedSessionStartResponse(body: Data) -> LocalControlAPIHTTPResponse {
        guard let sessionStarter else {
            return jsonErrorResponse(
                status: "503 Service Unavailable",
                statusCode: 503,
                errorCode: "wrapped_session_start_unavailable",
                message: "This Mac Agent cannot start a Wrapped Session."
            )
        }

        do {
            let request = body.isEmpty
                ? StartWrappedSessionRequest()
                : try decoder.decode(StartWrappedSessionRequest.self, from: body)
            return LocalControlAPIHTTPResponse(
                status: "200 OK",
                statusCode: 200,
                contentType: "application/json",
                body: try encoder.encode(sessionStarter.startWrappedSession(request))
            )
        } catch let error as WrappedSessionLaunchError {
            return jsonErrorResponse(
                status: wrappedSessionFailureStatus(for: error),
                statusCode: wrappedSessionFailureStatusCode(for: error),
                errorCode: error.apiErrorCode,
                message: error.userMessage
            )
        } catch {
            return jsonErrorResponse(
                status: "400 Bad Request",
                statusCode: 400,
                errorCode: "wrapped_session_start_failed",
                message: "The Wrapped Session could not be started."
            )
        }
    }

    private func planningArtifactAttachmentResponse(body: Data) -> LocalControlAPIHTTPResponse {
        guard let artifactAttacher else {
            return jsonErrorResponse(
                status: "503 Service Unavailable",
                statusCode: 503,
                errorCode: "planning_artifact_attachment_unavailable",
                message: "This Mac Agent cannot attach a planning artifact."
            )
        }

        do {
            let request = try decoder.decode(AttachPlanningArtifactRequest.self, from: body)
            return LocalControlAPIHTTPResponse(
                status: "200 OK",
                statusCode: 200,
                contentType: "application/json",
                body: try encoder.encode(artifactAttacher.attachPlanningArtifact(request))
            )
        } catch let error as PlanningArtifactResolutionError {
            return jsonErrorResponse(
                status: attachmentFailureStatus(for: error),
                statusCode: attachmentFailureStatusCode(for: error),
                errorCode: error.apiErrorCode,
                message: error.userMessage
            )
        } catch {
            return jsonErrorResponse(
                status: "400 Bad Request",
                statusCode: 400,
                errorCode: "planning_artifact_attachment_failed",
                message: "The Planning Artifact attachment request could not be completed."
            )
        }
    }

    private func pairingCompletionResponse(body: Data) -> LocalControlAPIHTTPResponse {
        guard let pairingService else {
            return jsonErrorResponse(
                status: "503 Service Unavailable",
                statusCode: 503,
                errorCode: "pairing_unavailable",
                message: "Pairing is unavailable on this Mac Agent."
            )
        }

        do {
            let request = try decoder.decode(PairingCompletionRequest.self, from: body)
            return LocalControlAPIHTTPResponse(
                status: "200 OK",
                statusCode: 200,
                contentType: "application/json",
                body: try encoder.encode(pairingService.completePairing(request))
            )
        } catch MacPairingServiceError.invitationExpired {
            return jsonErrorResponse(
                status: "410 Gone",
                statusCode: 410,
                errorCode: "pairing_invitation_expired",
                message: "The pairing invitation has expired."
            )
        } catch MacPairingServiceError.unknownInvitation, MacPairingServiceError.invalidInvitationSecret {
            return jsonErrorResponse(
                status: "401 Unauthorized",
                statusCode: 401,
                errorCode: "pairing_invitation_invalid",
                message: "The pairing invitation is invalid."
            )
        } catch {
            return jsonErrorResponse(
                status: "400 Bad Request",
                statusCode: 400,
                errorCode: "pairing_failed",
                message: "Pairing failed."
            )
        }
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
                body: encodedErrorBody(errorCode: "foreground_state_unavailable", message: "Foreground state is unavailable.")
            )
        }
    }

    private func authorizationFailureResponse(_ result: PairedControlAPIAuthorizationResult) -> LocalControlAPIHTTPResponse {
        switch result {
        case .authorized:
            return jsonErrorResponse(
                status: "500 Internal Server Error",
                statusCode: 500,
                errorCode: "authorization_state_invalid",
                message: "Authorization reached an invalid state."
            )
        case .requiresTLS:
            return jsonErrorResponse(
                status: "426 Upgrade Required",
                statusCode: 426,
                errorCode: "paired_tls_required",
                message: "The Control API requires the paired TLS channel."
            )
        case .missingIdentity:
            return jsonErrorResponse(
                status: "401 Unauthorized",
                statusCode: 401,
                errorCode: "paired_identity_required",
                message: "Paired owner device credentials are required."
            )
        case .invalidIdentity:
            return jsonErrorResponse(
                status: "403 Forbidden",
                statusCode: 403,
                errorCode: "paired_identity_invalid",
                message: "Paired owner device credentials are invalid."
            )
        case .secretStoreUnavailable:
            return jsonErrorResponse(
                status: "503 Service Unavailable",
                statusCode: 503,
                errorCode: "pairing_secret_store_unavailable",
                message: "Pairing secret material is unavailable."
            )
        }
    }

    private func jsonErrorResponse(status: String, statusCode: Int, errorCode: String, message: String) -> LocalControlAPIHTTPResponse {
        LocalControlAPIHTTPResponse(
            status: status,
            statusCode: statusCode,
            contentType: "application/json",
            body: encodedErrorBody(errorCode: errorCode, message: message)
        )
    }

    private func encodedErrorBody(errorCode: String, message: String) -> Data {
        (try? encoder.encode(ControlAPIErrorResponse(error: errorCode, message: message)))
            ?? Data("{\"error\":\"\(errorCode)\",\"message\":\"\(message)\"}".utf8)
    }

    private func attachmentFailureStatus(for error: PlanningArtifactResolutionError) -> String {
        switch error {
        case .missingReference:
            return "400 Bad Request"
        case .artifactNotFound:
            return "404 Not Found"
        case .ghUnauthenticated:
            return "401 Unauthorized"
        case .invalidGitHubResponse, .ghFailed:
            return "502 Bad Gateway"
        }
    }

    private func attachmentFailureStatusCode(for error: PlanningArtifactResolutionError) -> Int {
        switch error {
        case .missingReference:
            return 400
        case .artifactNotFound:
            return 404
        case .ghUnauthenticated:
            return 401
        case .invalidGitHubResponse, .ghFailed:
            return 502
        }
    }

    private func wrappedSessionFailureStatus(for error: WrappedSessionLaunchError) -> String {
        switch error {
        case .noActivePlanningArtifact:
            return "409 Conflict"
        case .activeSessionAlreadyRunning:
            return "409 Conflict"
        case .baselineCaptureFailed, .tmuxLaunchFailed:
            return "502 Bad Gateway"
        }
    }

    private func wrappedSessionFailureStatusCode(for error: WrappedSessionLaunchError) -> Int {
        switch error {
        case .noActivePlanningArtifact, .activeSessionAlreadyRunning:
            return 409
        case .baselineCaptureFailed, .tmuxLaunchFailed:
            return 502
        }
    }

    private func pendingInputReplyFailureStatus(for error: PendingInputReplyError) -> String {
        switch error {
        case .noActiveSession, .noPendingInput:
            return "409 Conflict"
        case .uncertainInputRequiresConfirmation, .emptyReply:
            return "400 Bad Request"
        case .inputSendFailed:
            return "502 Bad Gateway"
        }
    }

    private func pendingInputReplyFailureStatusCode(for error: PendingInputReplyError) -> Int {
        switch error {
        case .noActiveSession, .noPendingInput:
            return 409
        case .uncertainInputRequiresConfirmation, .emptyReply:
            return 400
        case .inputSendFailed:
            return 502
        }
    }

    private func approvalDecisionFailureStatus(for error: ApprovalDecisionError) -> String {
        switch error {
        case .noActiveSession, .noPendingApprovalRequest, .staleRequest, .duplicateDecision:
            return "409 Conflict"
        case .decisionSendFailed:
            return "502 Bad Gateway"
        }
    }

    private func approvalDecisionFailureStatusCode(for error: ApprovalDecisionError) -> Int {
        switch error {
        case .noActiveSession, .noPendingApprovalRequest, .staleRequest, .duplicateDecision:
            return 409
        case .decisionSendFailed:
            return 502
        }
    }

    private func draftCommentFailureStatus(for error: DraftCommentError) -> String {
        switch error {
        case .noActivePlanningArtifact, .noPreparedDraftComment, .staleDraftComment, .duplicateDecision:
            return "409 Conflict"
        case .emptyCommentBody:
            return "400 Bad Request"
        case .githubPostFailed:
            return "502 Bad Gateway"
        }
    }

    private func draftCommentFailureStatusCode(for error: DraftCommentError) -> Int {
        switch error {
        case .noActivePlanningArtifact, .noPreparedDraftComment, .staleDraftComment, .duplicateDecision:
            return 409
        case .emptyCommentBody:
            return 400
        case .githubPostFailed:
            return 502
        }
    }
}

public final class LocalControlAPIServer: @unchecked Sendable {
    public static let foregroundStatePath = "/v1/foreground-state"
    public static let pairingCompletionPath = "/v1/pairings/complete"
    public static let planningArtifactAttachmentPath = "/v1/planning-artifact/attachment"
    public static let wrappedSessionStartPath = "/v1/agent-session/start"
    public static let pendingInputReplyPath = "/v1/pending-input/reply"
    public static let approvalDecisionPath = "/v1/approval-request/decision"
    public static let draftCommentPreparePath = "/v1/draft-comment/prepare"
    public static let draftCommentDecisionPath = "/v1/draft-comment/decision"

    private let responder: LocalControlAPIResponder
    private let requestedPort: UInt16
    private let channelSecurity: ControlAPIChannelSecurity
    private let lock = NSLock()
    private var socketFileDescriptor: Int32 = -1
    private var isStopping = false
    private var serverThread: Thread?

    public init(
        provider: any ControlAPIProviding,
        pairingService: MacPairingService? = nil,
        securityPolicy: ControlAPISecurityPolicy,
        channelSecurity: ControlAPIChannelSecurity = .plainHTTP,
        port: UInt16 = 5577
    ) {
        self.responder = LocalControlAPIResponder(
            provider: provider,
            pairingService: pairingService,
            securityPolicy: securityPolicy
        )
        self.requestedPort = port
        self.channelSecurity = channelSecurity
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

        let scheme = channelSecurity == .pairedTLS ? "https" : "http"
        return URL(string: "\(scheme)://127.0.0.1:\(port)")!
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

        let response = responder.response(
            for: String(decoding: buffer.prefix(byteCount), as: UTF8.self),
            channelSecurity: channelSecurity
        )
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

struct ParsedLocalControlAPIRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    init(rawRequest: String) {
        let parts = rawRequest.components(separatedBy: "\r\n\r\n")
        let headerBlock = parts.first ?? ""
        body = Data(parts.dropFirst().joined(separator: "\r\n\r\n").utf8)

        let lines = headerBlock.components(separatedBy: "\r\n")
        let firstLineParts = (lines.first ?? "").split(separator: " ")
        method = firstLineParts.first.map(String.init) ?? ""

        if firstLineParts.count > 1 {
            path = String(firstLineParts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        } else {
            path = ""
        }

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }

            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[name] = value
        }
        headers = parsedHeaders
    }
}
#endif
