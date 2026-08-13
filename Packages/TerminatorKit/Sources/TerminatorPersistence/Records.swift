import Foundation
import SwiftData
import TerminatorCore

@Model
final class HostRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var hostname: String
    var port: Int
    // Legacy v1 fields are retained so migration never drops existing associations.
    var username: String
    var credentialID: UUID?
    var authenticationModeRawValue: String = "manual"
    var identityID: UUID?
    var credentialIDs: [UUID] = []
    var authenticationMethodsData: Data?
    var group: String?
    var tags: [String]
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(profile: HostProfile) {
        id = profile.id
        displayName = profile.displayName
        hostname = profile.hostname
        port = profile.port
        username = profile.authentication.manualUsername ?? ""
        credentialID = profile.authentication.credentialIDs.first
        group = profile.group
        tags = profile.tags
        notes = profile.notes
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        deletedAt = profile.deletedAt
        applyAuthentication(profile.authentication)
    }

    var domain: HostProfile {
        let authentication: HostAuthentication
        if authenticationModeRawValue == "identity", let identityID {
            authentication = .identity(identityID)
        } else {
            let ids = credentialIDs.isEmpty ? credentialID.map { [$0] } ?? [] : credentialIDs
            let methods = authenticationMethodsData
                .flatMap { try? JSONDecoder().decode([AuthenticationMethod].self, from: $0) }
                ?? ids.map(AuthenticationMethod.accessKey)
            authentication = .manual(username: username, authenticationMethods: methods)
        }
        return HostProfile(
            id: id,
            displayName: displayName,
            hostname: hostname,
            port: port,
            authentication: authentication,
            group: group,
            tags: tags,
            notes: notes,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    func apply(_ profile: HostProfile) {
        displayName = profile.displayName
        hostname = profile.hostname
        port = profile.port
        group = profile.group
        tags = profile.tags
        notes = profile.notes
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        deletedAt = profile.deletedAt
        applyAuthentication(profile.authentication)
    }

    private func applyAuthentication(_ authentication: HostAuthentication) {
        switch authentication {
        case .identity(let id):
            authenticationModeRawValue = "identity"
            identityID = id
            username = ""
            credentialIDs = []
            authenticationMethodsData = nil
            credentialID = nil
        case .manual(let value, let methods):
            authenticationModeRawValue = "manual"
            identityID = nil
            username = value
            credentialIDs = methods.compactMap(\.credentialID)
            credentialID = credentialIDs.first
            authenticationMethodsData = try? JSONEncoder().encode(methods)
        }
    }
}

@Model
final class CredentialRecord {
    @Attribute(.unique) var id: UUID
    var label: String
    var kindRawValue: String
    var secretID: UUID
    var fingerprint: String?
    var accessKeyData: Data?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var secretPurgedAt: Date?

    init(metadata: CredentialMetadata) {
        id = metadata.id
        label = metadata.label
        kindRawValue = metadata.kind.rawValue
        secretID = metadata.secretID.rawValue
        fingerprint = metadata.fingerprint
        accessKeyData = metadata.accessKey.flatMap { try? JSONEncoder().encode($0) }
        createdAt = metadata.createdAt
        updatedAt = metadata.updatedAt
        deletedAt = metadata.deletedAt
        secretPurgedAt = metadata.secretPurgedAt
    }

    var domain: CredentialMetadata {
        let decodedKey = accessKeyData.flatMap { try? JSONDecoder().decode(AccessKeyMetadata.self, from: $0) }
        let migrated = migrateLegacyKeyIfNeeded(decodedKey)
        return CredentialMetadata(
            id: id,
            label: label,
            kind: migrated.kind,
            secretID: SecretID(rawValue: secretID),
            accessKey: migrated.key,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            secretPurgedAt: secretPurgedAt
        )
    }

    func apply(_ metadata: CredentialMetadata) {
        label = metadata.label
        kindRawValue = metadata.kind.rawValue
        secretID = metadata.secretID.rawValue
        fingerprint = metadata.fingerprint
        accessKeyData = metadata.accessKey.flatMap { try? JSONEncoder().encode($0) }
        createdAt = metadata.createdAt
        updatedAt = metadata.updatedAt
        deletedAt = metadata.deletedAt
        secretPurgedAt = metadata.secretPurgedAt
    }

    private func migrateLegacyKeyIfNeeded(_ decoded: AccessKeyMetadata?) -> (kind: CredentialKind, key: AccessKeyMetadata?) {
        if let decoded { return (.accessKey, decoded) }
        switch kindRawValue {
        case "privateKey":
            let id = SecretID(rawValue: secretID)
            return (
                .accessKey,
                AccessKeyMetadata(
                    algorithm: .ed25519,
                    backend: .software,
                    origin: .migrated,
                    publicKey: "Legacy key — upgrade required",
                    fingerprint: fingerprint?.isEmpty == false ? fingerprint! : "Unknown",
                    privateMaterialID: id,
                    compatibility: .needsUpgrade
                )
            )
        case "keyPassphrase":
            return (.legacyPassphrase, nil)
        default:
            return (CredentialKind(rawValue: kindRawValue) ?? .password, nil)
        }
    }
}

@Model
final class IdentityRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var username: String
    var credentialIDs: [UUID]
    var authenticationMethodsData: Data?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(profile: IdentityProfile) {
        id = profile.id
        name = profile.name
        username = profile.username
        credentialIDs = profile.credentialIDs
        authenticationMethodsData = try? JSONEncoder().encode(profile.authenticationMethods)
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        deletedAt = profile.deletedAt
    }

    var domain: IdentityProfile {
        IdentityProfile(
            id: id,
            name: name,
            username: username,
            authenticationMethods: authenticationMethodsData
                .flatMap { try? JSONDecoder().decode([AuthenticationMethod].self, from: $0) }
                ?? credentialIDs.map(AuthenticationMethod.accessKey),
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    func apply(_ profile: IdentityProfile) {
        name = profile.name
        username = profile.username
        credentialIDs = profile.credentialIDs
        authenticationMethodsData = try? JSONEncoder().encode(profile.authenticationMethods)
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        deletedAt = profile.deletedAt
    }
}

@Model
final class ChangeRecord {
    @Attribute(.unique) var id: UUID
    var entityRawValue: String
    var entityID: UUID
    var operationRawValue: String
    var timestamp: Date
    var schemaVersion: Int
    var beforeSnapshot: Data?
    var afterSnapshot: Data?
    var source: String

    init(entry: HistoryEntry) {
        id = entry.id
        entityRawValue = entry.entity.rawValue
        entityID = entry.entityID
        operationRawValue = entry.operation.rawValue
        timestamp = entry.timestamp
        schemaVersion = entry.schemaVersion
        beforeSnapshot = entry.beforeSnapshot
        afterSnapshot = entry.afterSnapshot
        source = entry.source
    }

    var domain: HistoryEntry {
        HistoryEntry(
            id: id,
            entity: HistoryEntity(rawValue: entityRawValue) ?? .host,
            entityID: entityID,
            operation: HistoryOperation(rawValue: operationRawValue) ?? .updated,
            timestamp: timestamp,
            schemaVersion: schemaVersion,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot,
            source: source
        )
    }
}
