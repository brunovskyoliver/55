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
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}
