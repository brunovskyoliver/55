import AgentShared
import iPhoneCore
import XCTest

final class OwnerDevicePairingTests: XCTestCase {
    func testScansInvitationCompletesPairingAndStoresCredentials() async throws {
        let invitation = PairingInvitation(
            id: "invitation-id",
            macAgentName: "Test Mac",
            controlBaseURL: URL(string: "https://127.0.0.1:5577")!,
            expiresAt: Date(timeIntervalSince1970: 1_787_800_120),
            invitationSecret: "invitation-secret"
        )
        let client = FakePairingCompletionClient(
            response: PairingCompletionResponse(
                credentials: PairedControlCredentials(
                    deviceID: "owner-device-id",
                    bearerToken: "owner-bearer-token",
                    controlBaseURL: invitation.controlBaseURL
                ),
                pairedAt: Date(timeIntervalSince1970: 1_787_800_000)
            )
        )
        let credentialStore = InMemoryPairedControlCredentialStore()
        let service = OwnerDevicePairingService(
            client: client,
            credentialStore: credentialStore,
            ownerDeviceName: "Owner iPhone",
            ownerDevicePublicKey: "owner-public-key"
        )

        let response = try await service.completePairing(from: invitation.encodedQRPayload())

        XCTAssertEqual(response.credentials.deviceID, "owner-device-id")
        let request = try XCTUnwrap(client.capturedRequest)
        XCTAssertEqual(request.invitationID, "invitation-id")
        XCTAssertEqual(request.invitationSecret, "invitation-secret")
        XCTAssertEqual(request.ownerDeviceName, "Owner iPhone")
        XCTAssertEqual(request.ownerDevicePublicKey, "owner-public-key")
        XCTAssertEqual(client.capturedControlBaseURL, invitation.controlBaseURL)

        let storedCredentials = try XCTUnwrap(credentialStore.credentials(forDeviceID: "owner-device-id"))
        XCTAssertEqual(storedCredentials.authorizationHeaderValue, "Bearer owner-bearer-token")
    }

    func testHTTPForegroundStateClientRequiresPairedTLSURL() async {
        let client = HTTPForegroundStateClient(baseURL: URL(string: "http://127.0.0.1:5577")!)

        do {
            _ = try await client.fetchForegroundState()
            XCTFail("Expected plaintext foreground sync to be rejected.")
        } catch {
            XCTAssertEqual(error as? ForegroundStateClientError, .pairedTLSRequired)
        }
    }

    func testHTTPForegroundStateClientRevokePostsAuthorizedRequest() async throws {
        let credentials = PairedControlCredentials(
            deviceID: "owner-device-id",
            bearerToken: "owner-bearer-token",
            controlBaseURL: URL(string: "https://127.0.0.1:5577")!
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CapturingURLProtocol.response = HTTPURLResponse(
            url: credentials.controlBaseURL.appending(path: "v1/pairings/revoke"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )
        CapturingURLProtocol.responseData = Data("{}".utf8)
        CapturingURLProtocol.capturedRequest = nil
        let client = HTTPForegroundStateClient(
            baseURL: credentials.controlBaseURL,
            credentials: credentials,
            session: session
        )

        try await client.revokePairing()

        let request = try XCTUnwrap(CapturingURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/pairings/revoke")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Owner-Device-ID"), "owner-device-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-bearer-token")
    }
}

private final class FakePairingCompletionClient: PairingCompletionClient, @unchecked Sendable {
    private let lock = NSLock()
    private let response: PairingCompletionResponse
    private var _capturedRequest: PairingCompletionRequest?
    private var _capturedControlBaseURL: URL?

    var capturedRequest: PairingCompletionRequest? {
        lock.withLock {
            _capturedRequest
        }
    }

    var capturedControlBaseURL: URL? {
        lock.withLock {
            _capturedControlBaseURL
        }
    }

    init(response: PairingCompletionResponse) {
        self.response = response
    }

    func completePairing(
        _ request: PairingCompletionRequest,
        controlBaseURL: URL,
        certFingerprintSHA256: String?
    ) async throws -> PairingCompletionResponse {
        lock.withLock {
            _capturedRequest = request
            _capturedControlBaseURL = controlBaseURL
        }
        return response
    }
}

private final class InMemoryPairedControlCredentialStore: PairedControlCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentialsByDeviceID: [String: PairedControlCredentials] = [:]

    func store(_ credentials: PairedControlCredentials) throws {
        lock.withLock {
            credentialsByDeviceID[credentials.deviceID] = credentials
        }
    }

    func credentials(forDeviceID deviceID: String) throws -> PairedControlCredentials? {
        lock.withLock {
            credentialsByDeviceID[deviceID]
        }
    }

    func delete(deviceID: String) throws {
        _ = lock.withLock {
            credentialsByDeviceID.removeValue(forKey: deviceID)
        }
    }
}

private final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _capturedRequest: URLRequest?
    nonisolated(unsafe) private static var _response: HTTPURLResponse?
    nonisolated(unsafe) private static var _responseData = Data()

    static var capturedRequest: URLRequest? {
        get { lock.withLock { _capturedRequest } }
        set { lock.withLock { _capturedRequest = newValue } }
    }

    static var response: HTTPURLResponse? {
        get { lock.withLock { _response } }
        set { lock.withLock { _response = newValue } }
    }

    static var responseData: Data {
        get { lock.withLock { _responseData } }
        set { lock.withLock { _responseData = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capturedRequest = request
        let response = Self.response ?? HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}
