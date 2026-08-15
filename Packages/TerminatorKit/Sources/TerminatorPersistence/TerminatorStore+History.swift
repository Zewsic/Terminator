import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
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

    func revertHost(using entry: HistoryEntry) throws {
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

    func revertCredential(using entry: HistoryEntry) throws {
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

    func revertIdentity(using entry: HistoryEntry) throws {
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

}
