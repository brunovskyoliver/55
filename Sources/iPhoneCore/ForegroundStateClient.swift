import AgentShared
import Foundation

public protocol ForegroundStateClient: Sendable {
    func fetchForegroundState() async throws -> ControlForegroundResponse
}

public struct HTTPForegroundStateClient: ForegroundStateClient {
    private let baseURL: URL
    private let credentials: PairedControlCredentials?
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(baseURL: URL, credentials: PairedControlCredentials? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func fetchForegroundState() async throws -> ControlForegroundResponse {
        guard baseURL.scheme == "https" else {
            throw ForegroundStateClientError.pairedTLSRequired
        }

        var request = URLRequest(url: baseURL.appending(path: "v1/foreground-state"))
        if let credentials {
            request.setValue(credentials.deviceID, forHTTPHeaderField: "X-Owner-Device-ID")
            request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ForegroundStateClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return try decoder.decode(ControlForegroundResponse.self, from: data)
    }
}

public enum ForegroundStateClientError: Error, Equatable {
    case pairedTLSRequired
    case unexpectedStatusCode(Int)
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
