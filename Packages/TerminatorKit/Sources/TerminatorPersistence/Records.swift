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
    var sessionPersistenceRawValue: String = SessionPersistence.none.rawValue
    var remoteShellPresetRawValue: String = RemoteShellPreset.loginShell.rawValue
    var remoteShellCustomPath: String = ""
    var connectCommands: String = ""
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
        sessionPersistenceRawValue = profile.sessionPersistence.rawValue
        remoteShellPresetRawValue = profile.remoteShell.preset.rawValue
        remoteShellCustomPath = profile.remoteShell.customPath
        connectCommands = profile.connectCommands
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
            sessionPersistence: SessionPersistence(rawValue: sessionPersistenceRawValue) ?? .none,
            remoteShell: RemoteShell(
                preset: RemoteShellPreset(rawValue: remoteShellPresetRawValue) ?? .loginShell,
                customPath: remoteShellCustomPath
            ),
            connectCommands: connectCommands,
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
        sessionPersistenceRawValue = profile.sessionPersistence.rawValue
        remoteShellPresetRawValue = profile.remoteShell.preset.rawValue
        remoteShellCustomPath = profile.remoteShell.customPath
        connectCommands = profile.connectCommands
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
                    publicKey: TerminatorCoreLocalization.text("legacyKey.upgradeRequired"),
                    fingerprint: fingerprint?.isEmpty == false ? fingerprint! : TerminatorCoreLocalization.text("common.unknown"),
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

@Model
final class KnownHostRecord {
    @Attribute(.unique) var lookupKey: String?
    var endpoint: String
    var id: UUID
    var algorithm: String
    var publicKey: Data
    var fingerprint: String
    var createdAt: Date
    var updatedAt: Date

    init(key: KnownHostKey) {
        lookupKey = Self.makeLookupKey(endpoint: key.endpoint, algorithm: key.algorithm)
        endpoint = key.endpoint; id = key.id; algorithm = key.algorithm
        publicKey = key.publicKey; fingerprint = key.fingerprint
        createdAt = key.createdAt; updatedAt = key.updatedAt
    }

    var domain: KnownHostKey {
        KnownHostKey(
            id: id, endpoint: endpoint, algorithm: algorithm, publicKey: publicKey,
            fingerprint: fingerprint, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    func apply(_ key: KnownHostKey) {
        lookupKey = Self.makeLookupKey(endpoint: key.endpoint, algorithm: key.algorithm)
        endpoint = key.endpoint
        id = key.id; algorithm = key.algorithm; publicKey = key.publicKey
        fingerprint = key.fingerprint; createdAt = key.createdAt; updatedAt = key.updatedAt
    }

    func populateLookupKeyIfNeeded() {
        if lookupKey == nil {
            lookupKey = Self.makeLookupKey(endpoint: endpoint, algorithm: algorithm)
        }
    }

    private static func makeLookupKey(endpoint: String, algorithm: String) -> String {
        endpoint.lowercased() + "\u{1f}" + algorithm.lowercased()
    }
}

@Model
final class SessionLogRecord {
    @Attribute(.unique) var id: UUID
    var hostID: UUID
    var hostDisplayName: String
    var terminalRawValue: String
    var startedAt: Date
    var endedAt: Date?
    var byteCount: Int64
    var reconnectCount: Int
    var stateRawValue: String
    var isPinned: Bool
    var relativePath: String
    var encryptionKeyID: UUID

    init(log: SessionLogMetadata) {
        id = log.id; hostID = log.hostID; hostDisplayName = log.hostDisplayName
        terminalRawValue = log.terminal.rawValue; startedAt = log.startedAt; endedAt = log.endedAt
        byteCount = log.byteCount; reconnectCount = log.reconnectCount
        stateRawValue = log.state.rawValue; isPinned = log.isPinned
        relativePath = log.relativePath; encryptionKeyID = log.encryptionKeyID.rawValue
    }

    var domain: SessionLogMetadata {
        SessionLogMetadata(
            id: id, hostID: hostID, hostDisplayName: hostDisplayName,
            terminal: TerminalApplication(rawValue: terminalRawValue) ?? .other,
            startedAt: startedAt, endedAt: endedAt, byteCount: byteCount,
            reconnectCount: reconnectCount,
            state: SessionLogState(rawValue: stateRawValue) ?? .incomplete,
            isPinned: isPinned, relativePath: relativePath,
            encryptionKeyID: SecretID(rawValue: encryptionKeyID)
        )
    }

    func apply(_ log: SessionLogMetadata) {
        hostID = log.hostID; hostDisplayName = log.hostDisplayName
        terminalRawValue = log.terminal.rawValue; startedAt = log.startedAt; endedAt = log.endedAt
        byteCount = log.byteCount; reconnectCount = log.reconnectCount
        stateRawValue = log.state.rawValue; isPinned = log.isPinned
        relativePath = log.relativePath; encryptionKeyID = log.encryptionKeyID.rawValue
    }
}
