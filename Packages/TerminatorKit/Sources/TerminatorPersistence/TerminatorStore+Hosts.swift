import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
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

}
