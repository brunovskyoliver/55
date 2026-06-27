import Foundation

public struct PairingInvitation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var macAgentName: String
    public var controlBaseURL: URL
    public var expiresAt: Date
    public var invitationSecret: String

    public init(
        id: String,
        macAgentName: String,
        controlBaseURL: URL,
        expiresAt: Date,
        invitationSecret: String
    ) {
        self.id = id
        self.macAgentName = macAgentName
        self.controlBaseURL = controlBaseURL
        self.expiresAt = expiresAt
        self.invitationSecret = invitationSecret
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

    public init(deviceID: String, bearerToken: String, controlBaseURL: URL) {
        self.deviceID = deviceID
        self.bearerToken = bearerToken
        self.controlBaseURL = controlBaseURL
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
}

public protocol PairedControlCredentialStore: Sendable {
    func store(_ credentials: PairedControlCredentials) throws
    func credentials(forDeviceID deviceID: String) throws -> PairedControlCredentials?
}
