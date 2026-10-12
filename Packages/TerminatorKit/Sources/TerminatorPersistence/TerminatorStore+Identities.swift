import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
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

    public func purgeIdentity(id: UUID) throws {
        guard let record = try fetchIdentity(id: id) else { throw PersistenceError.identityNotFound }
        guard try identityReferenceCount(id: id) == 0 else { throw PersistenceError.identityInUse }
        let before = record.domain
        modelContext.delete(record)
        try appendHistory(entity: .identity, entityID: id, operation: .purged, before: before, after: nil as IdentityProfile?)
        try modelContext.save()
    }

}
