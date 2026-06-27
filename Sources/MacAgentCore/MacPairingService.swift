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
        timeToLive: TimeInterval = 120
    ) throws -> PairingInvitation {
        let invitation = PairingInvitation(
            id: try tokenGenerator.token(byteCount: 12),
            macAgentName: macAgentName,
            controlBaseURL: controlBaseURL,
            expiresAt: clock.now.addingTimeInterval(timeToLive),
            invitationSecret: try tokenGenerator.token(byteCount: 32)
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
                controlBaseURL: invitation.controlBaseURL
            ),
            pairedAt: now
        )
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
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
