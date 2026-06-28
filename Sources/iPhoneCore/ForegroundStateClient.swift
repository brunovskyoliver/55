import AgentShared
import CryptoKit
import Foundation

public protocol ForegroundStateClient: Sendable {
    func fetchForegroundState() async throws -> ControlForegroundResponse
}

public protocol PlanningArtifactAttachmentClient: Sendable {
    func attachPlanningArtifact(_ request: AttachPlanningArtifactRequest) async throws -> AttachPlanningArtifactResponse
}

public protocol WrappedSessionStartClient: Sendable {
    func startWrappedSession(_ request: StartWrappedSessionRequest) async throws -> StartWrappedSessionResponse
}

public protocol WrappedSessionStopClient: Sendable {
    func stopWrappedSession(_ request: StopWrappedSessionRequest) async throws -> StopWrappedSessionResponse
}

public protocol PendingInputReplyClient: Sendable {
    func submitPendingInputReply(_ request: SubmitPendingInputReplyRequest) async throws -> SubmitPendingInputReplyResponse
}

public protocol ApprovalDecisionClient: Sendable {
    func submitApprovalDecision(_ request: SubmitApprovalDecisionRequest) async throws -> SubmitApprovalDecisionResponse
}

public protocol DraftCommentClient: Sendable {
    func prepareDraftComment(_ request: PrepareDraftCommentRequest) async throws -> PrepareDraftCommentResponse
    func submitDraftCommentDecision(_ request: SubmitDraftCommentDecisionRequest) async throws -> SubmitDraftCommentDecisionResponse
}

public protocol PairingRevokeClient: Sendable {
    func revokePairing() async throws
}

public struct HTTPForegroundStateClient: ForegroundStateClient {
    private let baseURL: URL
    private let credentials: PairedControlCredentials?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL, credentials: PairedControlCredentials? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func fetchForegroundState() async throws -> ControlForegroundResponse {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        let request = authorizedRequest(url: baseURL.appending(path: "v1/foreground-state"))

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ForegroundStateClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return try decoder.decode(ControlForegroundResponse.self, from: data)
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let credentials {
            request.setValue(credentials.deviceID, forHTTPHeaderField: "X-Owner-Device-ID")
            request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

extension HTTPForegroundStateClient: PlanningArtifactAttachmentClient {
    public func attachPlanningArtifact(_ request: AttachPlanningArtifactRequest) async throws -> AttachPlanningArtifactResponse {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        var urlRequest = authorizedRequest(url: baseURL.appending(path: "v1/planning-artifact/attachment"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let errorResponse = try? decoder.decode(ControlAPIErrorResponse.self, from: data)
            throw ForegroundStateClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Planning Artifact attachment failed."
            )
        }

        return try decoder.decode(AttachPlanningArtifactResponse.self, from: data)
    }
}

extension HTTPForegroundStateClient: WrappedSessionStartClient {
    public func startWrappedSession(_ request: StartWrappedSessionRequest = StartWrappedSessionRequest()) async throws -> StartWrappedSessionResponse {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        var urlRequest = authorizedRequest(url: baseURL.appending(path: "v1/agent-session/start"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let errorResponse = try? decoder.decode(ControlAPIErrorResponse.self, from: data)
            throw ForegroundStateClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Wrapped Session start failed."
            )
        }

        return try decoder.decode(StartWrappedSessionResponse.self, from: data)
    }
}

extension HTTPForegroundStateClient: WrappedSessionStopClient {
    public func stopWrappedSession(_ request: StopWrappedSessionRequest) async throws -> StopWrappedSessionResponse {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        var urlRequest = authorizedRequest(url: baseURL.appending(path: "v1/agent-session/stop"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let errorResponse = try? decoder.decode(ControlAPIErrorResponse.self, from: data)
            throw ForegroundStateClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Wrapped Session stop failed."
            )
        }

        return try decoder.decode(StopWrappedSessionResponse.self, from: data)
    }
}

extension HTTPForegroundStateClient: PendingInputReplyClient {
    public func submitPendingInputReply(_ request: SubmitPendingInputReplyRequest) async throws -> SubmitPendingInputReplyResponse {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        var urlRequest = authorizedRequest(url: baseURL.appending(path: "v1/pending-input/reply"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let errorResponse = try? decoder.decode(ControlAPIErrorResponse.self, from: data)
            throw ForegroundStateClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Pending Input reply failed."
            )
        }

        return try decoder.decode(SubmitPendingInputReplyResponse.self, from: data)
    }
}

extension HTTPForegroundStateClient: ApprovalDecisionClient {
    public func submitApprovalDecision(_ request: SubmitApprovalDecisionRequest) async throws -> SubmitApprovalDecisionResponse {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        var urlRequest = authorizedRequest(url: baseURL.appending(path: "v1/approval-request/decision"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let errorResponse = try? decoder.decode(ControlAPIErrorResponse.self, from: data)
            throw ForegroundStateClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Approval decision failed."
            )
        }

        return try decoder.decode(SubmitApprovalDecisionResponse.self, from: data)
    }
}

extension HTTPForegroundStateClient: DraftCommentClient {
    public func prepareDraftComment(_ request: PrepareDraftCommentRequest = PrepareDraftCommentRequest()) async throws -> PrepareDraftCommentResponse {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        var urlRequest = authorizedRequest(url: baseURL.appending(path: "v1/draft-comment/prepare"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let errorResponse = try? decoder.decode(ControlAPIErrorResponse.self, from: data)
            throw ForegroundStateClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Draft Comment preparation failed."
            )
        }

        return try decoder.decode(PrepareDraftCommentResponse.self, from: data)
    }

    public func submitDraftCommentDecision(_ request: SubmitDraftCommentDecisionRequest) async throws -> SubmitDraftCommentDecisionResponse {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        var urlRequest = authorizedRequest(url: baseURL.appending(path: "v1/draft-comment/decision"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let errorResponse = try? decoder.decode(ControlAPIErrorResponse.self, from: data)
            throw ForegroundStateClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Draft Comment decision failed."
            )
        }

        return try decoder.decode(SubmitDraftCommentDecisionResponse.self, from: data)
    }
}

extension HTTPForegroundStateClient: PairingRevokeClient {
    public func revokePairing() async throws {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        var urlRequest = authorizedRequest(url: baseURL.appending(path: "v1/pairings/revoke"))
        urlRequest.httpMethod = "POST"

        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let errorResponse = try? decoder.decode(ControlAPIErrorResponse.self, from: data)
            throw ForegroundStateClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.message ?? "Pairing revoke failed."
            )
        }
    }
}

public enum ForegroundStateClientError: Error, Equatable {
    case pairedTLSRequired
    case unexpectedStatusCode(Int)
    case requestFailed(statusCode: Int, message: String)
}

// MARK: - Cert-Pinning URLSession

/// Returns a `URLSession` that pins the server TLS certificate by SHA-256 fingerprint.
/// Pass this session to `HTTPForegroundStateClient` when connecting to the Mac Agent over LAN.
public func pinnedURLSession(certFingerprintSHA256: String) -> URLSession {
    let delegate = PinningURLSessionDelegate(expectedFingerprint: certFingerprintSHA256)
    return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
}

/// `URLSessionDelegate` that validates the server leaf-cert fingerprint against a stored SHA-256.
/// Bypasses hostname validation so the client can connect to a raw LAN IP (not the cert CN).
final class PinningURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Retrieve the leaf certificate using the iOS 15+ API.
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let derData = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: derData)
            .map { String(format: "%02x", $0) }
            .joined()

        if fingerprint == expectedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

public struct ForegroundStateLoader: Sendable {
    private let client: any ForegroundStateClient
    private let mapper: PlanningStateMapping

    public init(client: any ForegroundStateClient, mapper: PlanningStateMapping = PlanningStateMapper()) {
        self.client = client
        self.mapper = mapper
    }

    public func load() async throws -> PlanningCenteredState {
        try mapper.map(try await client.fetchForegroundState())
    }
}
