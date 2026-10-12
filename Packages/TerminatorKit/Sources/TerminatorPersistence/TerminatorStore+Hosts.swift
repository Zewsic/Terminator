import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
    public func listHosts(includeDeleted: Bool = false) throws -> [HostProfile] {
        let segments = try allCommandSegments()
        return try modelContext.fetch(FetchDescriptor<HostRecord>())
            .map { record in
                var profile = try migrateLegacyPasswordMethods(record.domain)
                profile.connectCommandSegments = segments[profile.id] ?? []
                return profile
            }
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func host(id: UUID) throws -> HostProfile? {
        guard let record = try fetchHost(id: id) else { return nil }
        var profile = try migrateLegacyPasswordMethods(record.domain)
        profile.connectCommandSegments = try commandSegments(for: id)
        return profile
    }

    public func saveHost(_ host: HostProfile) throws {
        var validated = try host.validated()
        let incomingSegments = validated.connectCommandSegments
        validated.connectCommandSegments = ConnectCommandScript.stored(incomingSegments)
        if !incomingSegments.isEmpty {
            validated.connectCommands = ConnectCommandScript.render(
                validated.connectCommandSegments, scripts: try activeSnippetScripts()
            )
        }
        try validateReferences(for: validated)
        let before = try fetchHost(id: validated.id)?.domain
        var current = validated
        current.updatedAt = .now
        if before == nil { current.createdAt = current.updatedAt }
        try persistHost(current)
        try replaceCommandSegments(hostID: current.id, segments: current.connectCommandSegments)
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

    public func purgeHost(id: UUID) throws {
        guard let record = try fetchHost(id: id) else { throw PersistenceError.hostNotFound }
        let before = record.domain
        modelContext.delete(record)
        try appendHistory(entity: .host, entityID: id, operation: .purged, before: before, after: nil as HostProfile?)
        try modelContext.save()
    }

}
