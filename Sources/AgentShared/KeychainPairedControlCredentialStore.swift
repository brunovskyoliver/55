#if canImport(Security)
import Foundation
import Security

public final class KeychainPairedControlCredentialStore: PairedControlCredentialStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "AgentSessionControl.OwnerDeviceCredentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func store(_ credentials: PairedControlCredentials) throws {
        let data = try encoder.encode(credentials)
        var query = baseQuery(deviceID: credentials.deviceID)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainPairedControlCredentialStoreError.unhandledStatus(status)
        }
    }

    public func credentials(forDeviceID deviceID: String) throws -> PairedControlCredentials? {
        var query = baseQuery(deviceID: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainPairedControlCredentialStoreError.unhandledStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainPairedControlCredentialStoreError.unexpectedPayload
        }

        return try decoder.decode(PairedControlCredentials.self, from: data)
    }

    public func delete(deviceID: String) throws {
        let status = SecItemDelete(baseQuery(deviceID: deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPairedControlCredentialStoreError.unhandledStatus(status)
        }
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

public enum KeychainPairedControlCredentialStoreError: Error, Equatable {
    case unhandledStatus(OSStatus)
    case unexpectedPayload
}
#endif
