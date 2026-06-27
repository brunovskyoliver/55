import AgentShared
import Foundation

public protocol ForegroundStateClient: Sendable {
    func fetchForegroundState() async throws -> ControlForegroundResponse
}

public struct HTTPForegroundStateClient: ForegroundStateClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func fetchForegroundState() async throws -> ControlForegroundResponse {
        let url = baseURL.appending(path: "v1/foreground-state")
        let (data, response) = try await session.data(from: url)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ForegroundStateClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return try decoder.decode(ControlForegroundResponse.self, from: data)
    }
}

public enum ForegroundStateClientError: Error, Equatable {
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
