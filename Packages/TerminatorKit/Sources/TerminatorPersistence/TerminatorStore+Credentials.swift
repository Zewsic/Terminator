import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
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

}
