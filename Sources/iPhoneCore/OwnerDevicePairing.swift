import AgentShared
import Foundation

public struct OwnerDevicePairingScanner: Sendable {
    public init() {}

    public func scan(_ qrPayload: String) throws -> PairingInvitation {
        try PairingInvitation.decodeQRPayload(qrPayload)
    }
}

public protocol PairingCompletionClient: Sendable {
    func completePairing(
        _ request: PairingCompletionRequest,
        controlBaseURL: URL
    ) async throws -> PairingCompletionResponse
}

public struct HTTPPairingCompletionClient: PairingCompletionClient {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func completePairing(
        _ request: PairingCompletionRequest,
        controlBaseURL: URL
    ) async throws -> PairingCompletionResponse {
        guard controlBaseURL.scheme == "https" else {
            throw OwnerDevicePairingError.pairedTLSRequired
        }

        var urlRequest = URLRequest(url: controlBaseURL.appending(path: "v1/pairings/complete"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw OwnerDevicePairingError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return try decoder.decode(PairingCompletionResponse.self, from: data)
    }
}

public struct OwnerDevicePairingService: Sendable {
    private let scanner: OwnerDevicePairingScanner
    private let client: any PairingCompletionClient
    private let credentialStore: any PairedControlCredentialStore
    private let ownerDeviceName: String
    private let ownerDevicePublicKey: String

    public init(
        scanner: OwnerDevicePairingScanner = OwnerDevicePairingScanner(),
        client: any PairingCompletionClient,
        credentialStore: any PairedControlCredentialStore,
        ownerDeviceName: String,
        ownerDevicePublicKey: String
    ) {
        self.scanner = scanner
        self.client = client
        self.credentialStore = credentialStore
        self.ownerDeviceName = ownerDeviceName
        self.ownerDevicePublicKey = ownerDevicePublicKey
    }

    public func completePairing(from qrPayload: String) async throws -> PairingCompletionResponse {
        let invitation = try scanner.scan(qrPayload)
        let request = PairingCompletionRequest(
            invitationID: invitation.id,
            invitationSecret: invitation.invitationSecret,
            ownerDeviceName: ownerDeviceName,
            ownerDevicePublicKey: ownerDevicePublicKey
        )
        let response = try await client.completePairing(request, controlBaseURL: invitation.controlBaseURL)
        try credentialStore.store(response.credentials)
        return response
    }
}

public enum OwnerDevicePairingError: Error, Equatable {
    case pairedTLSRequired
    case unexpectedStatusCode(Int)
}
