import Foundation

public struct PairingInvitation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var macAgentName: String
    public var controlBaseURL: URL
    public var expiresAt: Date
    public var invitationSecret: String
    /// SHA-256 fingerprint (lowercase hex) of the server's self-signed TLS certificate.
    /// Used by the iPhone to pin the connection rather than trusting the system CA store.
    public var certFingerprintSHA256: String?
    /// Bonjour service name (`_agentctl._tcp`) for re-resolving the Mac's current LAN IP.
    public var bonjourServiceName: String?

    public init(
        id: String,
        macAgentName: String,
        controlBaseURL: URL,
        expiresAt: Date,
        invitationSecret: String,
        certFingerprintSHA256: String? = nil,
        bonjourServiceName: String? = nil
    ) {
        self.id = id
        self.macAgentName = macAgentName
        self.controlBaseURL = controlBaseURL
        self.expiresAt = expiresAt
        self.invitationSecret = invitationSecret
        self.certFingerprintSHA256 = certFingerprintSHA256
        self.bonjourServiceName = bonjourServiceName
    }

    public func encodedQRPayload() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decodeQRPayload(_ payload: String) throws -> PairingInvitation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PairingInvitation.self, from: Data(payload.utf8))
    }
}

public struct PairingCompletionRequest: Codable, Equatable, Sendable {
    public var invitationID: PairingInvitation.ID
    public var invitationSecret: String
    public var ownerDeviceName: String
    public var ownerDevicePublicKey: String

    public init(
        invitationID: PairingInvitation.ID,
        invitationSecret: String,
        ownerDeviceName: String,
        ownerDevicePublicKey: String
    ) {
        self.invitationID = invitationID
        self.invitationSecret = invitationSecret
        self.ownerDeviceName = ownerDeviceName
        self.ownerDevicePublicKey = ownerDevicePublicKey
    }
}

public struct PairingCompletionResponse: Codable, Equatable, Sendable {
    public var credentials: PairedControlCredentials
    public var pairedAt: Date

    public init(credentials: PairedControlCredentials, pairedAt: Date) {
        self.credentials = credentials
        self.pairedAt = pairedAt
    }
}

public struct PairedControlCredentials: Codable, Equatable, Sendable {
    public var deviceID: String
    public var bearerToken: String
    public var controlBaseURL: URL
    /// SHA-256 fingerprint (lowercase hex) of the server TLS certificate for cert pinning.
    public var certFingerprintSHA256: String?
    /// Bonjour service name for re-resolving the Mac's current LAN IP at connect time.
    public var bonjourServiceName: String?

    public init(
        deviceID: String,
        bearerToken: String,
        controlBaseURL: URL,
        certFingerprintSHA256: String? = nil,
        bonjourServiceName: String? = nil
    ) {
        self.deviceID = deviceID
        self.bearerToken = bearerToken
        self.controlBaseURL = controlBaseURL
        self.certFingerprintSHA256 = certFingerprintSHA256
        self.bonjourServiceName = bonjourServiceName
    }

    public var authorizationHeaderValue: String {
        "Bearer \(bearerToken)"
    }
}

public struct PairingSecretMaterial: Codable, Equatable, Sendable {
    public var deviceID: String
    public var ownerDeviceName: String
    public var ownerDevicePublicKey: String
    public var bearerToken: String
    public var pairedAt: Date

    public init(
        deviceID: String,
        ownerDeviceName: String,
        ownerDevicePublicKey: String,
        bearerToken: String,
        pairedAt: Date
    ) {
        self.deviceID = deviceID
        self.ownerDeviceName = ownerDeviceName
        self.ownerDevicePublicKey = ownerDevicePublicKey
        self.bearerToken = bearerToken
        self.pairedAt = pairedAt
    }
}

public protocol PairingSecretMaterialStore: Sendable {
    func store(_ material: PairingSecretMaterial) throws
    func material(forDeviceID deviceID: String) throws -> PairingSecretMaterial?
    func delete(deviceID: String) throws
}

public protocol PairedControlCredentialStore: Sendable {
    func store(_ credentials: PairedControlCredentials) throws
    func credentials(forDeviceID deviceID: String) throws -> PairedControlCredentials?
    func delete(deviceID: String) throws
}
