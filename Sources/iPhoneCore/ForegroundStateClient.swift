import AgentShared
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

public protocol PendingInputReplyClient: Sendable {
    func submitPendingInputReply(_ request: SubmitPendingInputReplyRequest) async throws -> SubmitPendingInputReplyResponse
}

public protocol ApprovalDecisionClient: Sendable {
    func submitApprovalDecision(_ request: SubmitApprovalDecisionRequest) async throws -> SubmitApprovalDecisionResponse
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

public enum ForegroundStateClientError: Error, Equatable {
    case pairedTLSRequired
    case unexpectedStatusCode(Int)
    case requestFailed(statusCode: Int, message: String)
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
