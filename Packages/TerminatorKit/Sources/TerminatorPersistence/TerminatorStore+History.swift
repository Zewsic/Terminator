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
        case .tunnel: try revertTunnel(using: entry)
        case .snippet: try revertSnippet(using: entry)
        case .task: throw PersistenceError.taskChangeIsIrreversible
        }
        try modelContext.save()
    }

    public func recordHistory(
        entity: HistoryEntity,
        entityID: UUID,
        operation: HistoryOperation,
        before: Data?,
        after: Data?
    ) throws {
        modelContext.insert(ChangeRecord(entry: HistoryEntry(
            entity: entity,
            entityID: entityID,
            operation: operation,
            beforeSnapshot: before,
            afterSnapshot: after
        )))
        try modelContext.save()
    }

    func revertHost(using entry: HistoryEntry) throws {
        let before = try fetchHost(id: entry.entityID)?.domain
        let target = try entry.beforeSnapshot.map { try decoder.decode(HostProfile.self, from: $0) }
        let after: HostProfile
        if var target {
            if case .manual(let username, let targetMethods) = target.authentication {
                let currentMethods = before?.authentication.authenticationMethods ?? []
                target.authentication = .manual(
                    username: username,
                    authenticationMethods: preservingCurrentPassword(in: targetMethods, currentMethods: currentMethods)
                )
            }
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

    func revertSnippet(using entry: HistoryEntry) throws {
        let before = try fetchSnippet(id: entry.entityID)?.domain
        let target = try entry.beforeSnapshot.map { try decoder.decode(SnippetProfile.self, from: $0) }
        let after: SnippetProfile
        if var target {
            target.updatedAt = .now
            try persistSnippet(target)
            after = target
        } else if var current = before {
            current.deletedAt = .now
            current.updatedAt = .now
            try persistSnippet(current)
            after = current
        } else { throw PersistenceError.snippetNotFound }
        try refreshConnectCommands(referencing: entry.entityID)
        try appendHistory(entity: .snippet, entityID: entry.entityID, operation: .restored, before: before, after: after)
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

    func revertTunnel(using entry: HistoryEntry) throws {
        let before = try fetchTunnel(id: entry.entityID)?.domain
        let target = try entry.beforeSnapshot.map { try decoder.decode(TunnelProfile.self, from: $0) }
        let after: TunnelProfile
        if var target {
            target.updatedAt = .now
            try persistTunnel(target)
            after = target
        } else if var current = before {
            current.deletedAt = .now
            current.updatedAt = .now
            try persistTunnel(current)
            after = current
        } else { throw PersistenceError.tunnelNotFound }
        try appendHistory(entity: .tunnel, entityID: entry.entityID, operation: .restored, before: before, after: after)
    }

    func revertIdentity(using entry: HistoryEntry) throws {
        let before = try fetchIdentity(id: entry.entityID)?.domain
        let target = try entry.beforeSnapshot.map { try decoder.decode(IdentityProfile.self, from: $0) }
        let after: IdentityProfile
        if var target {
            target.authenticationMethods = preservingCurrentPassword(
                in: target.authenticationMethods,
                currentMethods: before?.authenticationMethods ?? []
            )
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

    /// History stores references to secrets, not the secret bytes themselves. A password may
    /// have been replaced and purged after a snapshot was recorded, so reverting metadata must
    /// retain the current password reference instead of resurrecting an unavailable one.
    private func preservingCurrentPassword(
        in historicalMethods: [AuthenticationMethod],
        currentMethods: [AuthenticationMethod]
    ) -> [AuthenticationMethod] {
        var methods = historicalMethods.filter { $0.passwordSecretID == nil }
        guard let currentPassword = currentMethods.first(where: { $0.passwordSecretID != nil }) else {
            return methods
        }
        let historicalIndex = historicalMethods.firstIndex(where: { $0.passwordSecretID != nil }) ?? 0
        methods.insert(currentPassword, at: min(historicalIndex, methods.count))
        return methods
    }

}
