import Foundation
import SwiftData
import TerminatorCore

public enum PersistenceError: LocalizedError, Equatable, Sendable {
    case hostNotFound
    case credentialNotFound
    case identityNotFound
    case historyEntryNotFound
    case unsupportedHistorySchema(Int)
    case secretPurgeIsIrreversible
    case credentialInUse
    case identityInUse
    case referencedCredentialUnavailable
    case referencedIdentityUnavailable

    public var errorDescription: String? {
        switch self {
        case .hostNotFound: TerminatorCoreLocalization.text("error.store.hostNotFound")
        case .credentialNotFound: TerminatorCoreLocalization.text("error.store.credentialNotFound")
        case .identityNotFound: TerminatorCoreLocalization.text("error.store.identityNotFound")
        case .historyEntryNotFound: TerminatorCoreLocalization.text("error.store.historyEntryNotFound")
        case .unsupportedHistorySchema(let version): TerminatorCoreLocalization.text("error.store.unsupportedHistorySchema", version)
        case .secretPurgeIsIrreversible: TerminatorCoreLocalization.text("error.store.secretPurgeIsIrreversible")
        case .credentialInUse: TerminatorCoreLocalization.text("error.store.credentialInUse")
        case .identityInUse: TerminatorCoreLocalization.text("error.store.identityInUse")
        case .referencedCredentialUnavailable: TerminatorCoreLocalization.text("error.store.referencedCredentialUnavailable")
        case .referencedIdentityUnavailable: TerminatorCoreLocalization.text("error.store.referencedIdentityUnavailable")
        }
    }
}

@ModelActor
public actor TerminatorStore: HostRepository, CredentialRepository, IdentityRepository, HistoryRepository, KnownHostRepository, SessionLogRepository {
    private var encoder: JSONEncoder { JSONEncoder() }
    private var decoder: JSONDecoder { JSONDecoder() }

    public func listHosts(includeDeleted: Bool = false) throws -> [HostProfile] {
        try modelContext.fetch(FetchDescriptor<HostRecord>())
            .map { try migrateLegacyPasswordMethods($0.domain) }
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func host(id: UUID) throws -> HostProfile? {
        try fetchHost(id: id).map { try migrateLegacyPasswordMethods($0.domain) }
    }

    public func saveHost(_ host: HostProfile) throws {
        let validated = try host.validated()
        try validateReferences(for: validated)
        let before = try fetchHost(id: validated.id)?.domain
        var current = validated
        current.updatedAt = .now
        if before == nil { current.createdAt = current.updatedAt }
        try persistHost(current)
        try appendHistory(
            entity: .host,
            entityID: current.id,
            operation: before == nil ? .created : .updated,
            before: before,
            after: current
        )
        try modelContext.save()
    }

    public func deleteHost(id: UUID) throws {
        guard let record = try fetchHost(id: id) else { throw PersistenceError.hostNotFound }
        let before = record.domain
        var after = before
        after.deletedAt = .now
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .host, entityID: id, operation: .deleted, before: before, after: after)
        try modelContext.save()
    }

    public func restoreHost(id: UUID) throws {
        guard let record = try fetchHost(id: id) else { throw PersistenceError.hostNotFound }
        let before = record.domain
        var after = before
        try validateReferences(for: after)
        after.deletedAt = nil
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .host, entityID: id, operation: .restored, before: before, after: after)
        try modelContext.save()
    }

    public func knownHosts(endpoint: String) throws -> [KnownHostKey] {
        let descriptor = FetchDescriptor<KnownHostRecord>(predicate: #Predicate { $0.endpoint == endpoint })
        let records = try modelContext.fetch(descriptor)
        let needsMigration = records.contains { $0.lookupKey == nil }
        for record in records { record.populateLookupKeyIfNeeded() }
        if needsMigration { try modelContext.save() }
        return records.map(\.domain)
            .sorted { $0.algorithm < $1.algorithm }
    }

    public func saveKnownHost(_ key: KnownHostKey) throws {
        let algorithm = key.algorithm
        var descriptor = FetchDescriptor<KnownHostRecord>(
            predicate: #Predicate { $0.endpoint == key.endpoint && $0.algorithm == algorithm }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first { record.apply(key) }
        else { modelContext.insert(KnownHostRecord(key: key)) }
        try modelContext.save()
    }

    public func removeKnownHost(endpoint: String, algorithm: String?) throws {
        let records = try modelContext.fetch(
            FetchDescriptor<KnownHostRecord>(predicate: #Predicate { $0.endpoint == endpoint })
        )
        for record in records where algorithm == nil || record.algorithm == algorithm {
            modelContext.delete(record)
        }
        if !records.isEmpty { try modelContext.save() }
    }

    public func listSessionLogs() throws -> [SessionLogMetadata] {
        try modelContext.fetch(FetchDescriptor<SessionLogRecord>())
            .map(\.domain)
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func sessionLog(id: UUID) throws -> SessionLogMetadata? {
        var descriptor = FetchDescriptor<SessionLogRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.domain
    }

    public func saveSessionLog(_ log: SessionLogMetadata) throws {
        var descriptor = FetchDescriptor<SessionLogRecord>(predicate: #Predicate { $0.id == log.id })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first { record.apply(log) }
        else { modelContext.insert(SessionLogRecord(log: log)) }
        try modelContext.save()
    }

    public func deleteSessionLog(id: UUID) throws {
        var descriptor = FetchDescriptor<SessionLogRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

    public func listCredentials(includeDeleted: Bool = false) throws -> [CredentialMetadata] {
        try modelContext.fetch(FetchDescriptor<CredentialRecord>())
            .map(\.domain)
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public func credential(id: UUID) throws -> CredentialMetadata? { try fetchCredential(id: id)?.domain }

    public func saveCredential(_ credential: CredentialMetadata) throws {
        let validated = try credential.validated()
        let before = try fetchCredential(id: validated.id)?.domain
        var current = validated
        current.updatedAt = .now
        if before == nil { current.createdAt = current.updatedAt }
        try persistCredential(current)
        let operation: HistoryOperation
        if before == nil {
            operation = .created
        } else if before?.secretPurgedAt == nil, current.secretPurgedAt != nil {
            operation = .purged
        } else {
            operation = .updated
        }
        try appendHistory(entity: .credential, entityID: current.id, operation: operation, before: before, after: current)
        try modelContext.save()
    }

    public func deleteCredential(id: UUID) throws {
        guard let record = try fetchCredential(id: id) else { throw PersistenceError.credentialNotFound }
        guard try credentialReferenceCount(id: id) == 0 else { throw PersistenceError.credentialInUse }
        let before = record.domain
        var after = before
        after.deletedAt = .now
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .credential, entityID: id, operation: .deleted, before: before, after: after)
        try modelContext.save()
    }

    public func listIdentities(includeDeleted: Bool = false) throws -> [IdentityProfile] {
        try modelContext.fetch(FetchDescriptor<IdentityRecord>())
            .map { try migrateLegacyPasswordMethods($0.domain) }
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func identity(id: UUID) throws -> IdentityProfile? {
        try fetchIdentity(id: id).map { try migrateLegacyPasswordMethods($0.domain) }
    }

    public func saveIdentity(_ identity: IdentityProfile) throws {
        let validated = try identity.validated()
        try validateCredentialReferences(validated.credentialIDs)
        let before = try fetchIdentity(id: validated.id)?.domain
        var current = validated
        current.updatedAt = .now
        if before == nil { current.createdAt = current.updatedAt }
        try persistIdentity(current)
        try appendHistory(
            entity: .identity,
            entityID: current.id,
            operation: before == nil ? .created : .updated,
            before: before,
            after: current
        )
        try modelContext.save()
    }

    public func deleteIdentity(id: UUID) throws {
        guard let record = try fetchIdentity(id: id) else { throw PersistenceError.identityNotFound }
        guard try identityReferenceCount(id: id) == 0 else { throw PersistenceError.identityInUse }
        let before = record.domain
        var after = before
        after.deletedAt = .now
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .identity, entityID: id, operation: .deleted, before: before, after: after)
        try modelContext.save()
    }

    public func restoreIdentity(id: UUID) throws {
        guard let record = try fetchIdentity(id: id) else { throw PersistenceError.identityNotFound }
        let before = record.domain
        var after = before
        try validateCredentialReferences(after.credentialIDs)
        after.deletedAt = nil
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .identity, entityID: id, operation: .restored, before: before, after: after)
        try modelContext.save()
    }

    public func listHistory(entity: HistoryEntity? = nil) throws -> [HistoryEntry] {
        let records: [ChangeRecord]
        if let entity {
            let rawValue = entity.rawValue
            records = try modelContext.fetch(
                FetchDescriptor<ChangeRecord>(predicate: #Predicate { $0.entityRawValue == rawValue })
            )
        } else {
            records = try modelContext.fetch(FetchDescriptor<ChangeRecord>())
        }
        return records.map(\.domain).sorted { $0.timestamp > $1.timestamp }
    }

    public func revert(historyEntryID: UUID) throws {
        guard let record = try fetchHistory(id: historyEntryID) else { throw PersistenceError.historyEntryNotFound }
        let entry = record.domain
        guard (1...3).contains(entry.schemaVersion) else {
            throw PersistenceError.unsupportedHistorySchema(entry.schemaVersion)
        }
        if entry.entity == .credential, entry.operation == .purged {
            throw PersistenceError.secretPurgeIsIrreversible
        }
        switch entry.entity {
        case .host: try revertHost(using: entry)
        case .credential: try revertCredential(using: entry)
        case .identity: try revertIdentity(using: entry)
        }
        try modelContext.save()
    }

    private func revertHost(using entry: HistoryEntry) throws {
        let before = try fetchHost(id: entry.entityID)?.domain
        let target = try entry.beforeSnapshot.map { try decoder.decode(HostProfile.self, from: $0) }
        let after: HostProfile
        if var target {
            try validateReferences(for: target)
            target.updatedAt = .now
            try persistHost(target)
            after = target
        } else if var current = before {
            current.deletedAt = .now
            current.updatedAt = .now
            try persistHost(current)
            after = current
        } else { throw PersistenceError.hostNotFound }
        try appendHistory(entity: .host, entityID: entry.entityID, operation: .restored, before: before, after: after)
    }

    private func migrateLegacyPasswordMethods(_ host: HostProfile) throws -> HostProfile {
        guard case .manual(let username, let methods) = host.authentication else { return host }
        var copy = host
        copy.authentication = .manual(
            username: username,
            authenticationMethods: try methods.map(migrateLegacyPasswordMethod)
        )
        return copy
    }

    private func migrateLegacyPasswordMethods(_ identity: IdentityProfile) throws -> IdentityProfile {
        var copy = identity
        copy.authenticationMethods = try identity.authenticationMethods.map(migrateLegacyPasswordMethod)
        return copy
    }

    private func migrateLegacyPasswordMethod(_ method: AuthenticationMethod) throws -> AuthenticationMethod {
        guard case .accessKey(let id) = method,
              let credential = try fetchCredential(id: id)?.domain,
              credential.kind == .password else { return method }
        return .password(secretID: credential.secretID)
    }

    private func revertCredential(using entry: HistoryEntry) throws {
        let before = try fetchCredential(id: entry.entityID)?.domain
        let target = try entry.beforeSnapshot.map { try decoder.decode(CredentialMetadata.self, from: $0) }
        let after: CredentialMetadata
        if var target {
            if let purgedAt = before?.secretPurgedAt { target.secretPurgedAt = purgedAt }
            target.updatedAt = .now
            try persistCredential(target)
            after = target
        } else if var current = before {
            guard try credentialReferenceCount(id: current.id) == 0 else { throw PersistenceError.credentialInUse }
            current.deletedAt = .now
            current.updatedAt = .now
            try persistCredential(current)
            after = current
        } else { throw PersistenceError.credentialNotFound }
        try appendHistory(entity: .credential, entityID: entry.entityID, operation: .restored, before: before, after: after)
    }

    private func revertIdentity(using entry: HistoryEntry) throws {
        let before = try fetchIdentity(id: entry.entityID)?.domain
        let target = try entry.beforeSnapshot.map { try decoder.decode(IdentityProfile.self, from: $0) }
        let after: IdentityProfile
        if var target {
            try validateCredentialReferences(target.credentialIDs)
            target.updatedAt = .now
            try persistIdentity(target)
            after = target
        } else if var current = before {
            guard try identityReferenceCount(id: current.id) == 0 else { throw PersistenceError.identityInUse }
            current.deletedAt = .now
            current.updatedAt = .now
            try persistIdentity(current)
            after = current
        } else { throw PersistenceError.identityNotFound }
        try appendHistory(entity: .identity, entityID: entry.entityID, operation: .restored, before: before, after: after)
    }

    private func validateReferences(for host: HostProfile) throws {
        switch host.authentication {
        case .identity(let id):
            guard let identity = try fetchIdentity(id: id)?.domain, !identity.isDeleted else {
                throw PersistenceError.referencedIdentityUnavailable
            }
        case .manual(_, let methods):
            try validateCredentialReferences(methods.compactMap(\.credentialID))
        }
    }

    private func validateCredentialReferences(_ ids: [UUID]) throws {
        for id in ids {
            guard let credential = try fetchCredential(id: id)?.domain,
                  !credential.isDeleted,
                  credential.isSecretAvailable else {
                throw PersistenceError.referencedCredentialUnavailable
            }
        }
    }

    private func credentialReferenceCount(id: UUID) throws -> Int {
        let hosts = try modelContext.fetch(FetchDescriptor<HostRecord>()).map(\.domain)
        let identities = try modelContext.fetch(FetchDescriptor<IdentityRecord>()).map(\.domain)
        return hosts.count { !$0.isDeleted && $0.authentication.credentialIDs.contains(id) }
            + identities.count { !$0.isDeleted && $0.credentialIDs.contains(id) }
    }

    private func identityReferenceCount(id: UUID) throws -> Int {
        try modelContext.fetch(FetchDescriptor<HostRecord>()).map(\.domain)
            .count { !$0.isDeleted && $0.authentication.identityID == id }
    }

    private func persistHost(_ host: HostProfile) throws {
        if let existing = try fetchHost(id: host.id) { existing.apply(host) }
        else { modelContext.insert(HostRecord(profile: host)) }
    }

    private func persistCredential(_ credential: CredentialMetadata) throws {
        if let existing = try fetchCredential(id: credential.id) { existing.apply(credential) }
        else { modelContext.insert(CredentialRecord(metadata: credential)) }
    }

    private func persistIdentity(_ identity: IdentityProfile) throws {
        if let existing = try fetchIdentity(id: identity.id) { existing.apply(identity) }
        else { modelContext.insert(IdentityRecord(profile: identity)) }
    }

    private func fetchHost(id: UUID) throws -> HostRecord? {
        var descriptor = FetchDescriptor<HostRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchCredential(id: UUID) throws -> CredentialRecord? {
        var descriptor = FetchDescriptor<CredentialRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchIdentity(id: UUID) throws -> IdentityRecord? {
        var descriptor = FetchDescriptor<IdentityRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchHistory(id: UUID) throws -> ChangeRecord? {
        var descriptor = FetchDescriptor<ChangeRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func appendHistory<Value: Encodable>(
        entity: HistoryEntity,
        entityID: UUID,
        operation: HistoryOperation,
        before: Value?,
        after: Value?
    ) throws {
        modelContext.insert(ChangeRecord(entry: HistoryEntry(
            entity: entity,
            entityID: entityID,
            operation: operation,
            beforeSnapshot: try before.map(encoder.encode),
            afterSnapshot: try after.map(encoder.encode)
        )))
    }
}
