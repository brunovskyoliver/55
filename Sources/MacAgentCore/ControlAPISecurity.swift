import AgentShared
import Foundation

public enum ControlAPIChannelSecurity: Equatable, Sendable {
    case plainHTTP
    case pairedTLS
}

public struct PairedControlAPIAuthorizer: Sendable {
    private let secretStore: any PairingSecretMaterialStore

    public init(secretStore: any PairingSecretMaterialStore) {
        self.secretStore = secretStore
    }

    public func authorize(headers: [String: String], channelSecurity: ControlAPIChannelSecurity) -> PairedControlAPIAuthorizationResult {
        guard channelSecurity == .pairedTLS else {
            return .requiresTLS
        }

        guard let deviceID = headers["x-owner-device-id"],
              let authorization = headers["authorization"],
              authorization.hasPrefix("Bearer ") else {
            return .missingIdentity
        }

        let bearerToken = String(authorization.dropFirst("Bearer ".count))

        do {
            guard let material = try secretStore.material(forDeviceID: deviceID) else {
                return .unknownDevice(deviceID: deviceID)
            }

            guard material.bearerToken == bearerToken else {
                return .invalidIdentity
            }

            return .authorized(deviceID: deviceID)
        } catch {
            return .secretStoreUnavailable
        }
    }
}

public enum PairedControlAPIAuthorizationResult: Equatable, Sendable {
    case authorized(deviceID: String)
    case unknownDevice(deviceID: String)
    case requiresTLS
    case missingIdentity
    case invalidIdentity
    case secretStoreUnavailable
}

public enum ControlAPISecurityPolicy: Sendable {
    case unsecuredDemo
    case pairedTLS(PairedControlAPIAuthorizer)

    func authorize(
        request: ParsedLocalControlAPIRequest,
        channelSecurity: ControlAPIChannelSecurity
    ) -> PairedControlAPIAuthorizationResult {
        switch self {
        case .unsecuredDemo:
            return .authorized(deviceID: "unsecured-demo")
        case .pairedTLS(let authorizer):
            return authorizer.authorize(headers: request.headers, channelSecurity: channelSecurity)
        }
    }

    func authorizePairingCompletion(channelSecurity: ControlAPIChannelSecurity) -> PairedControlAPIAuthorizationResult {
        switch self {
        case .unsecuredDemo:
            return .authorized(deviceID: "unsecured-demo")
        case .pairedTLS:
            return channelSecurity == .pairedTLS ? .authorized(deviceID: "pairing") : .requiresTLS
        }
    }
}
