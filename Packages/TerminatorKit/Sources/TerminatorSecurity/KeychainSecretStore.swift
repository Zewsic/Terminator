import Foundation
import LocalAuthentication
import Security
import TerminatorCore

public enum KeychainSecretStoreError: LocalizedError, Equatable, Sendable {
    case duplicateSecret
    case secretNotFound
    case unexpectedData
    case accessControlCreationFailed
    case securityStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .duplicateSecret: SecurityL10n.text(.errorDuplicateSecret)
        case .secretNotFound: SecurityL10n.text(.errorSecretNotFound)
        case .unexpectedData: SecurityL10n.text(.errorUnexpectedData)
        case .accessControlCreationFailed: SecurityL10n.text(.errorAccessControlCreationFailed)
        case .securityStatus(let status): SecurityL10n.text(.errorSecurityStatus, status)
        }
    }
}

public actor KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func store(_ secret: Data, for id: SecretID, access: SecretAccessPolicy) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.description,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: secret,
        ]
        switch access {
        case .deviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .userPresence:
            var error: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &error
            ) else {
                if let error { throw error.takeRetainedValue() }
                throw KeychainSecretStoreError.accessControlCreationFailed
            }
            query[kSecAttrAccessControl as String] = control
        }

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
        let context = LAContext()
        context.localizedReason = SecurityL10n.text(.authenticationUnlockPassphrase)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.description,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
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
