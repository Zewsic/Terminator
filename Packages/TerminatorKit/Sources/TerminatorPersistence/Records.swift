import Foundation
import SwiftData
import TerminatorCore

@Model
final class HostRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var hostname: String
    var port: Int
    var username: String
    var group: String?
    var tags: [String]
    var notes: String
    var credentialID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(profile: HostProfile) {
        id = profile.id
        displayName = profile.displayName
        hostname = profile.hostname
        port = profile.port
        username = profile.username
        group = profile.group
        tags = profile.tags
        notes = profile.notes
        credentialID = profile.credentialID
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        deletedAt = profile.deletedAt
    }

    var domain: HostProfile {
        HostProfile(
            id: id,
            displayName: displayName,
            hostname: hostname,
            port: port,
            username: username,
            group: group,
            tags: tags,
            notes: notes,
            credentialID: credentialID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    func apply(_ profile: HostProfile) {
        displayName = profile.displayName
        hostname = profile.hostname
        port = profile.port
        username = profile.username
        group = profile.group
        tags = profile.tags
        notes = profile.notes
        credentialID = profile.credentialID
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        deletedAt = profile.deletedAt
    }
}

@Model
final class CredentialRecord {
    @Attribute(.unique) var id: UUID
    var label: String
    var kindRawValue: String
    var secretID: UUID
    var fingerprint: String?
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
        createdAt = metadata.createdAt
        updatedAt = metadata.updatedAt
        deletedAt = metadata.deletedAt
        secretPurgedAt = metadata.secretPurgedAt
    }

    var domain: CredentialMetadata {
        CredentialMetadata(
            id: id,
            label: label,
            kind: CredentialKind(rawValue: kindRawValue) ?? .password,
            secretID: SecretID(rawValue: secretID),
            fingerprint: fingerprint,
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
        createdAt = metadata.createdAt
        updatedAt = metadata.updatedAt
        deletedAt = metadata.deletedAt
        secretPurgedAt = metadata.secretPurgedAt
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
