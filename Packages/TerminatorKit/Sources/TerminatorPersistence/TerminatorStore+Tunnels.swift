import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
    public func listTunnels(includeDeleted: Bool = false) throws -> [TunnelProfile] {
        try modelContext.fetch(FetchDescriptor<TunnelRecord>())
            .map(\.domain)
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func tunnel(id: UUID) throws -> TunnelProfile? {
        try fetchTunnel(id: id)?.domain
    }

    public func saveTunnel(_ tunnel: TunnelProfile) throws {
        let validated = try tunnel.validated()
        let before = try fetchTunnel(id: validated.id)?.domain
        var current = validated
        current.updatedAt = .now
        if before == nil { current.createdAt = current.updatedAt }
        try persistTunnel(current)
        try appendHistory(
            entity: .tunnel,
            entityID: current.id,
            operation: before == nil ? .created : .updated,
            before: before,
            after: current
        )
        try modelContext.save()
    }

    public func deleteTunnel(id: UUID) throws {
        guard let record = try fetchTunnel(id: id) else { throw PersistenceError.tunnelNotFound }
        let before = record.domain
        var after = before
        after.deletedAt = .now
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .tunnel, entityID: id, operation: .deleted, before: before, after: after)
        try modelContext.save()
    }

    func persistTunnel(_ tunnel: TunnelProfile) throws {
        if let existing = try fetchTunnel(id: tunnel.id) { existing.apply(tunnel) }
        else { modelContext.insert(TunnelRecord(profile: tunnel)) }
    }

    func fetchTunnel(id: UUID) throws -> TunnelRecord? {
        var descriptor = FetchDescriptor<TunnelRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
