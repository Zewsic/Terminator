import Foundation
import SwiftData
import TerminatorCore

public enum PersistenceError: LocalizedError, Equatable, Sendable {
    case hostNotFound
    case credentialNotFound
    case historyEntryNotFound
    case unsupportedHistorySchema(Int)
    case secretPurgeIsIrreversible

    public var errorDescription: String? {
        switch self {
        case .hostNotFound: "The host no longer exists."
        case .credentialNotFound: "The credential no longer exists."
        case .historyEntryNotFound: "The history entry no longer exists."
        case .unsupportedHistorySchema(let version): "History schema version \(version) is not supported."
        case .secretPurgeIsIrreversible: "Purged secret material cannot be restored."
        }
    }
}

@ModelActor
public actor TerminatorStore: HostRepository, CredentialRepository, HistoryRepository {
    private var encoder: JSONEncoder { JSONEncoder() }
    private var decoder: JSONDecoder { JSONDecoder() }

    public func listHosts(includeDeleted: Bool = false) throws -> [HostProfile] {
        let records = try modelContext.fetch(FetchDescriptor<HostRecord>())
        return records
            .map(\.domain)
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func host(id: UUID) throws -> HostProfile? {
        try fetchHost(id: id)?.domain
    }

    public func saveHost(_ host: HostProfile) throws {
        let validated = try host.validated()
        let before = try fetchHost(id: validated.id)?.domain
        var current = validated
        current.updatedAt = .now
        if before == nil {
            current.createdAt = current.updatedAt
        }
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
        after.deletedAt = nil
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .host, entityID: id, operation: .restored, before: before, after: after)
        try modelContext.save()
    }

    public func listCredentials(includeDeleted: Bool = false) throws -> [CredentialMetadata] {
        let records = try modelContext.fetch(FetchDescriptor<CredentialRecord>())
        return records
            .map(\.domain)
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public func credential(id: UUID) throws -> CredentialMetadata? {
        try fetchCredential(id: id)?.domain
    }

    public func saveCredential(_ credential: CredentialMetadata) throws {
        let validated = try credential.validated()
        let before = try fetchCredential(id: validated.id)?.domain
        var current = validated
        current.updatedAt = .now
        if before == nil {
            current.createdAt = current.updatedAt
        }
        try persistCredential(current)
        let operation: HistoryOperation
        if before == nil {
            operation = .created
        } else if before?.secretPurgedAt == nil, current.secretPurgedAt != nil {
            operation = .purged
        } else {
            operation = .updated
        }
        try appendHistory(
            entity: .credential,
            entityID: current.id,
            operation: operation,
            before: before,
            after: current
        )
        try modelContext.save()
    }

    public func deleteCredential(id: UUID) throws {
        guard let record = try fetchCredential(id: id) else { throw PersistenceError.credentialNotFound }
        let before = record.domain
        var after = before
        after.deletedAt = .now
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .credential, entityID: id, operation: .deleted, before: before, after: after)
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
        guard let record = try fetchHistory(id: historyEntryID) else {
            throw PersistenceError.historyEntryNotFound
        }
        let entry = record.domain
        guard entry.schemaVersion == 1 else {
            throw PersistenceError.unsupportedHistorySchema(entry.schemaVersion)
        }
        if entry.entity == .credential, entry.operation == .purged {
            throw PersistenceError.secretPurgeIsIrreversible
        }

        switch entry.entity {
        case .host:
            try revertHost(using: entry)
        case .credential:
            try revertCredential(using: entry)
        }
        try modelContext.save()
    }

    private func revertHost(using entry: HistoryEntry) throws {
        let before = try fetchHost(id: entry.entityID)?.domain
        let target = try entry.beforeSnapshot.map { try decoder.decode(HostProfile.self, from: $0) }
        let after: HostProfile

        if var target {
            target.updatedAt = .now
            try persistHost(target)
            after = target
        } else if var current = before {
            current.deletedAt = .now
            current.updatedAt = .now
            try persistHost(current)
            after = current
        } else {
            throw PersistenceError.hostNotFound
        }

        try appendHistory(entity: .host, entityID: entry.entityID, operation: .restored, before: before, after: after)
    }

    private func revertCredential(using entry: HistoryEntry) throws {
        let before = try fetchCredential(id: entry.entityID)?.domain
        let target = try entry.beforeSnapshot.map { try decoder.decode(CredentialMetadata.self, from: $0) }
        let after: CredentialMetadata

        if var target {
            // Metadata history must never make physically purged bytes appear available again.
            if let purgedAt = before?.secretPurgedAt {
                target.secretPurgedAt = purgedAt
            }
            target.updatedAt = .now
            try persistCredential(target)
            after = target
        } else if var current = before {
            current.deletedAt = .now
            current.updatedAt = .now
            try persistCredential(current)
            after = current
        } else {
            throw PersistenceError.credentialNotFound
        }

        try appendHistory(entity: .credential, entityID: entry.entityID, operation: .restored, before: before, after: after)
    }

    private func persistHost(_ host: HostProfile) throws {
        if let existing = try fetchHost(id: host.id) {
            existing.apply(host)
        } else {
            modelContext.insert(HostRecord(profile: host))
        }
    }

    private func persistCredential(_ credential: CredentialMetadata) throws {
        if let existing = try fetchCredential(id: credential.id) {
            existing.apply(credential)
        } else {
            modelContext.insert(CredentialRecord(metadata: credential))
        }
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
        let entry = HistoryEntry(
            entity: entity,
            entityID: entityID,
            operation: operation,
            beforeSnapshot: try before.map(encoder.encode),
            afterSnapshot: try after.map(encoder.encode)
        )
        modelContext.insert(ChangeRecord(entry: entry))
    }
}
