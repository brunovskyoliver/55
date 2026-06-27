#if canImport(Security)
import Foundation
import Security

public final class KeychainPairingSecretStore: PairingSecretMaterialStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "AgentSessionControl.Pairing", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func store(_ material: PairingSecretMaterial) throws {
        let data = try encoder.encode(material)
        var query = baseQuery(deviceID: material.deviceID)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainPairingSecretStoreError.unhandledStatus(status)
        }
    }

    public func material(forDeviceID deviceID: String) throws -> PairingSecretMaterial? {
        var query = baseQuery(deviceID: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainPairingSecretStoreError.unhandledStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainPairingSecretStoreError.unexpectedPayload
        }

        return try decoder.decode(PairingSecretMaterial.self, from: data)
    }

    private func baseQuery(deviceID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }
}

public enum KeychainPairingSecretStoreError: Error, Equatable {
    case unhandledStatus(OSStatus)
    case unexpectedPayload
}
#endif
