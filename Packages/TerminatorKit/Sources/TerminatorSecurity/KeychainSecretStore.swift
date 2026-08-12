import Foundation
import Security
import TerminatorCore

public enum KeychainSecretStoreError: LocalizedError, Equatable, Sendable {
    case duplicateSecret
    case secretNotFound
    case unexpectedData
    case securityStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .duplicateSecret: "A secret with this identifier already exists."
        case .secretNotFound: "The requested secret is not available."
        case .unexpectedData: "Keychain returned an unexpected value."
        case .securityStatus(let status): "Keychain operation failed with status \(status)."
        }
    }
}

public actor KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func store(_ secret: Data, for id: SecretID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.description,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: secret,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw KeychainSecretStoreError.duplicateSecret
        default:
            throw KeychainSecretStoreError.securityStatus(status)
        }
    }

    public func read(id: SecretID) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.description,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainSecretStoreError.unexpectedData }
            return data
        case errSecItemNotFound:
            throw KeychainSecretStoreError.secretNotFound
        default:
            throw KeychainSecretStoreError.securityStatus(status)
        }
    }

    public func purge(id: SecretID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.description,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.securityStatus(status)
        }
    }
}
