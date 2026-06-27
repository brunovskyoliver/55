import AgentShared
import MacAgentCore
import XCTest

final class PairingSecurityTests: XCTestCase {
    func testSuccessfulPairingStoresSecretMaterial() throws {
        let clock = MutablePairingClock(now: Date(timeIntervalSince1970: 1_787_800_000))
        let secretStore = InMemoryPairingSecretStore()
        let service = MacPairingService(
            secretStore: secretStore,
            tokenGenerator: FixedPairingTokenGenerator(tokens: [
                "invitation-id",
                "invitation-secret",
                "owner-device-id",
                "owner-bearer-token"
            ]),
            clock: clock
        )

        let invitation = try service.generateInvitation(
            macAgentName: "Test Mac",
            controlBaseURL: URL(string: "https://127.0.0.1:5577")!,
            timeToLive: 60
        )
        let response = try service.completePairing(
            PairingCompletionRequest(
                invitationID: invitation.id,
                invitationSecret: invitation.invitationSecret,
                ownerDeviceName: "Owner iPhone",
                ownerDevicePublicKey: "owner-public-key"
            )
        )

        XCTAssertEqual(response.credentials.deviceID, "owner-device-id")
        XCTAssertEqual(response.credentials.bearerToken, "owner-bearer-token")

        let material = try XCTUnwrap(secretStore.material(forDeviceID: "owner-device-id"))
        XCTAssertEqual(material.ownerDeviceName, "Owner iPhone")
        XCTAssertEqual(material.ownerDevicePublicKey, "owner-public-key")
        XCTAssertEqual(material.bearerToken, "owner-bearer-token")
    }

    func testExpiredInvitationIsRejected() throws {
        let clock = MutablePairingClock(now: Date(timeIntervalSince1970: 1_787_800_000))
        let service = MacPairingService(
            secretStore: InMemoryPairingSecretStore(),
            tokenGenerator: FixedPairingTokenGenerator(tokens: [
                "invitation-id",
                "invitation-secret"
            ]),
            clock: clock
        )

        let invitation = try service.generateInvitation(
            macAgentName: "Test Mac",
            controlBaseURL: URL(string: "https://127.0.0.1:5577")!,
            timeToLive: 5
        )
        clock.now = invitation.expiresAt.addingTimeInterval(1)

        XCTAssertThrowsError(
            try service.completePairing(
                PairingCompletionRequest(
                    invitationID: invitation.id,
                    invitationSecret: invitation.invitationSecret,
                    ownerDeviceName: "Owner iPhone",
                    ownerDevicePublicKey: "owner-public-key"
                )
            )
        ) { error in
            XCTAssertEqual(error as? MacPairingServiceError, .invitationExpired)
        }
    }

    func testControlAPIRejectsUnpairedForegroundStateRequest() {
        let responder = LocalControlAPIResponder(
            provider: DemoControlService(),
            securityPolicy: .pairedTLS(PairedControlAPIAuthorizer(secretStore: InMemoryPairingSecretStore()))
        )

        let response = responder.response(
            for: "GET /v1/foreground-state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            channelSecurity: .pairedTLS
        )

        XCTAssertEqual(response.statusCode, 401)
        let error = try? JSONDecoder().decode(ControlAPIErrorResponse.self, from: response.body)
        XCTAssertEqual(error?.error, "paired_identity_required")
    }

    func testControlAPIAcceptsPairedForegroundStateRequest() throws {
        let secretStore = InMemoryPairingSecretStore()
        try secretStore.store(
            PairingSecretMaterial(
                deviceID: "owner-device-id",
                ownerDeviceName: "Owner iPhone",
                ownerDevicePublicKey: "owner-public-key",
                bearerToken: "owner-bearer-token",
                pairedAt: Date(timeIntervalSince1970: 1_787_800_000)
            )
        )
        let responder = LocalControlAPIResponder(
            provider: DemoControlService(),
            securityPolicy: .pairedTLS(PairedControlAPIAuthorizer(secretStore: secretStore))
        )

        let response = responder.response(
            for: """
            GET /v1/foreground-state HTTP/1.1\r
            Host: 127.0.0.1\r
            X-Owner-Device-ID: owner-device-id\r
            Authorization: Bearer owner-bearer-token\r
            \r

            """,
            channelSecurity: .pairedTLS
        )

        XCTAssertEqual(response.statusCode, 200)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let foregroundState = try decoder.decode(ControlForegroundResponse.self, from: response.body)
        XCTAssertEqual(foregroundState.activePlanningArtifactID, "issue-2")
    }
}

private final class MutablePairingClock: PairingClock, @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private struct FixedPairingTokenGenerator: PairingTokenGenerating {
    private let tokens: LockedTokens

    init(tokens: [String]) {
        self.tokens = LockedTokens(tokens)
    }

    func token(byteCount: Int) throws -> String {
        try tokens.next()
    }
}

private final class LockedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    func next() throws -> String {
        try lock.withLock {
            guard !tokens.isEmpty else {
                throw FixedPairingTokenGeneratorError.noTokenAvailable
            }

            return tokens.removeFirst()
        }
    }
}

private enum FixedPairingTokenGeneratorError: Error {
    case noTokenAvailable
}

private final class InMemoryPairingSecretStore: PairingSecretMaterialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var materialByDeviceID: [String: PairingSecretMaterial] = [:]

    func store(_ material: PairingSecretMaterial) throws {
        lock.withLock {
            materialByDeviceID[material.deviceID] = material
        }
    }

    func material(forDeviceID deviceID: String) throws -> PairingSecretMaterial? {
        lock.withLock {
            materialByDeviceID[deviceID]
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
