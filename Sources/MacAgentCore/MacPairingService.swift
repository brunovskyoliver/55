import AgentShared
import Foundation
import Security

public protocol PairingClock: Sendable {
    var now: Date { get }
}

public struct SystemPairingClock: PairingClock {
    public init() {}

    public var now: Date {
        Date()
    }
}

public protocol PairingTokenGenerating: Sendable {
    func token(byteCount: Int) throws -> String
}

public struct SecurePairingTokenGenerator: PairingTokenGenerating {
    public init() {}

    public func token(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PairingTokenGeneratorError.randomBytesUnavailable(status)
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum PairingTokenGeneratorError: Error, Equatable {
    case randomBytesUnavailable(OSStatus)
}

public final class MacPairingService: @unchecked Sendable {
    private let secretStore: any PairingSecretMaterialStore
    private let tokenGenerator: any PairingTokenGenerating
    private let clock: any PairingClock
    private let lock = NSLock()
    private var invitations: [PairingInvitation.ID: PairingInvitation] = [:]
    /// In-memory push token registry: deviceID → (token, environment).
    /// Lost on process restart; owner devices re-register on each foreground session.
    private var pushTokens: [String: (token: String, environment: String)] = [:]

    public init(
        secretStore: any PairingSecretMaterialStore,
        tokenGenerator: any PairingTokenGenerating = SecurePairingTokenGenerator(),
        clock: any PairingClock = SystemPairingClock()
    ) {
        self.secretStore = secretStore
        self.tokenGenerator = tokenGenerator
        self.clock = clock
    }

    public func generateInvitation(
        macAgentName: String,
        controlBaseURL: URL,
        timeToLive: TimeInterval = 120,
        certFingerprintSHA256: String? = nil,
        bonjourServiceName: String? = nil
    ) throws -> PairingInvitation {
        let invitation = PairingInvitation(
            id: try tokenGenerator.token(byteCount: 12),
            macAgentName: macAgentName,
            controlBaseURL: controlBaseURL,
            expiresAt: clock.now.addingTimeInterval(timeToLive),
            invitationSecret: try tokenGenerator.token(byteCount: 32),
            certFingerprintSHA256: certFingerprintSHA256,
            bonjourServiceName: bonjourServiceName
        )

        lock.withLock {
            invitations[invitation.id] = invitation
        }

        return invitation
    }

    public func completePairing(_ request: PairingCompletionRequest) throws -> PairingCompletionResponse {
        let invitation = try consumeInvitation(id: request.invitationID)
        let now = clock.now

        guard now <= invitation.expiresAt else {
            throw MacPairingServiceError.invitationExpired
        }

        guard request.invitationSecret == invitation.invitationSecret else {
            throw MacPairingServiceError.invalidInvitationSecret
        }

        let material = PairingSecretMaterial(
            deviceID: try tokenGenerator.token(byteCount: 16),
            ownerDeviceName: request.ownerDeviceName,
            ownerDevicePublicKey: request.ownerDevicePublicKey,
            bearerToken: try tokenGenerator.token(byteCount: 32),
            pairedAt: now
        )
        try secretStore.store(material)

        return PairingCompletionResponse(
            credentials: PairedControlCredentials(
                deviceID: material.deviceID,
                bearerToken: material.bearerToken,
                controlBaseURL: invitation.controlBaseURL,
                certFingerprintSHA256: invitation.certFingerprintSHA256,
                bonjourServiceName: invitation.bonjourServiceName
            ),
            pairedAt: now
        )
    }

    public func revoke(deviceID: String) throws {
        guard try secretStore.material(forDeviceID: deviceID) != nil else {
            throw MacPairingServiceError.unknownDevice
        }

        try secretStore.delete(deviceID: deviceID)
        lock.withLock { _ = pushTokens.removeValue(forKey: deviceID) }
    }

    /// Register or update the APNs push token for a paired device.
    public func recordPushToken(deviceID: String, token: String, environment: String) throws {
        guard try secretStore.material(forDeviceID: deviceID) != nil else {
            throw MacPairingServiceError.unknownDevice
        }
        lock.withLock { pushTokens[deviceID] = (token: token, environment: environment) }
    }

    /// Remove a stale push token (e.g. after APNs returns 410 or BadDeviceToken).
    public func removePushToken(deviceID: String) {
        lock.withLock { _ = pushTokens.removeValue(forKey: deviceID) }
    }

    /// All currently registered push tokens, keyed by device ID.
    public func allPushTokens() -> [(deviceID: String, token: String, environment: String)] {
        lock.withLock {
            pushTokens.map { ($0.key, $0.value.token, $0.value.environment) }
        }
    }

    private func consumeInvitation(id: PairingInvitation.ID) throws -> PairingInvitation {
        try lock.withLock {
            guard let invitation = invitations.removeValue(forKey: id) else {
                throw MacPairingServiceError.unknownInvitation
            }

            return invitation
        }
    }
}

public enum MacPairingServiceError: Error, Equatable {
    case unknownInvitation
    case invitationExpired
    case invalidInvitationSecret
    case unknownDevice
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
