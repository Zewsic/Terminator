import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
    func persistHost(_ host: HostProfile) throws {
        if let existing = try fetchHost(id: host.id) { existing.apply(host) }
        else { modelContext.insert(HostRecord(profile: host)) }
    }

    func persistCredential(_ credential: CredentialMetadata) throws {
        if let existing = try fetchCredential(id: credential.id) { existing.apply(credential) }
        else { modelContext.insert(CredentialRecord(metadata: credential)) }
    }

    func persistIdentity(_ identity: IdentityProfile) throws {
        if let existing = try fetchIdentity(id: identity.id) { existing.apply(identity) }
        else { modelContext.insert(IdentityRecord(profile: identity)) }
    }

    func fetchHost(id: UUID) throws -> HostRecord? {
        var descriptor = FetchDescriptor<HostRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func fetchCredential(id: UUID) throws -> CredentialRecord? {
        var descriptor = FetchDescriptor<CredentialRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func fetchIdentity(id: UUID) throws -> IdentityRecord? {
        var descriptor = FetchDescriptor<IdentityRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func fetchHistory(id: UUID) throws -> ChangeRecord? {
        var descriptor = FetchDescriptor<ChangeRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func appendHistory<Value: Encodable>(
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
