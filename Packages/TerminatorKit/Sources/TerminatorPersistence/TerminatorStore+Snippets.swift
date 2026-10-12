import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
    public func listSnippets(includeDeleted: Bool = false) throws -> [SnippetProfile] {
        try modelContext.fetch(FetchDescriptor<SnippetRecord>())
            .map(\.domain)
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func snippet(id: UUID) throws -> SnippetProfile? {
        try fetchSnippet(id: id)?.domain
    }

    public func saveSnippet(_ snippet: SnippetProfile) throws {
        let validated = try snippet.validated()
        let before = try fetchSnippet(id: validated.id)?.domain
        var current = validated
        current.updatedAt = .now
        if before == nil { current.createdAt = current.updatedAt }
        try persistSnippet(current)
        try appendHistory(
            entity: .snippet,
            entityID: current.id,
            operation: before == nil ? .created : .updated,
            before: before,
            after: current
        )
        try refreshConnectCommands(referencing: current.id)
        try modelContext.save()
    }

    public func deleteSnippet(id: UUID) throws {
        guard let record = try fetchSnippet(id: id) else { throw PersistenceError.snippetNotFound }
        let before = record.domain
        var after = before
        after.deletedAt = .now
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .snippet, entityID: id, operation: .deleted, before: before, after: after)
        try refreshConnectCommands(referencing: id)
        try modelContext.save()
    }

    public func restoreSnippet(id: UUID) throws {
        guard let record = try fetchSnippet(id: id) else { throw PersistenceError.snippetNotFound }
        let before = record.domain
        var after = before
        after.deletedAt = nil
        after.updatedAt = .now
        record.apply(after)
        try appendHistory(entity: .snippet, entityID: id, operation: .restored, before: before, after: after)
        try refreshConnectCommands(referencing: id)
        try modelContext.save()
    }

    public func purgeSnippet(id: UUID) throws {
        guard let record = try fetchSnippet(id: id) else { throw PersistenceError.snippetNotFound }
        let before = record.domain
        modelContext.delete(record)
        try appendHistory(entity: .snippet, entityID: id, operation: .purged, before: before, after: nil as SnippetProfile?)
        try refreshConnectCommands(referencing: id)
        try modelContext.save()
    }

    public func noteSnippetUsed(id: UUID) throws {
        guard let record = try fetchSnippet(id: id) else { throw PersistenceError.snippetNotFound }
        var profile = record.domain
        profile.lastUsedAt = .now
        record.apply(profile)
        try modelContext.save()
    }

    public func importSnippet(_ snippet: SnippetProfile) throws {
        let validated = try snippet.validated()
        if let externalID = validated.externalID,
           let existing = try modelContext.fetch(FetchDescriptor<SnippetRecord>()).map(\.domain).first(where: { $0.externalID == externalID }) {
            var merged = validated
            merged.id = existing.id
            merged.createdAt = existing.createdAt
            merged.lastUsedAt = existing.lastUsedAt
            merged.deletedAt = existing.deletedAt
            try saveSnippet(merged)
            return
        }
        try saveSnippet(validated)
    }

    func persistSnippet(_ snippet: SnippetProfile) throws {
        if let existing = try fetchSnippet(id: snippet.id) { existing.apply(snippet) }
        else { modelContext.insert(SnippetRecord(profile: snippet)) }
    }

    func fetchSnippet(id: UUID) throws -> SnippetRecord? {
        var descriptor = FetchDescriptor<SnippetRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func commandSegments(for hostID: UUID) throws -> [ConnectCommandSegment] {
        let records = try modelContext.fetch(FetchDescriptor<HostCommandSegmentRecord>(
            predicate: #Predicate { $0.hostID == hostID }
        ))
        return records.sorted { $0.position < $1.position }.map(\.segment)
    }

    func allCommandSegments() throws -> [UUID: [ConnectCommandSegment]] {
        let records = try modelContext.fetch(FetchDescriptor<HostCommandSegmentRecord>())
        var grouped: [UUID: [(Int, ConnectCommandSegment)]] = [:]
        for record in records {
            grouped[record.hostID, default: []].append((record.position, record.segment))
        }
        return grouped.mapValues { pairs in
            pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func replaceCommandSegments(hostID: UUID, segments: [ConnectCommandSegment]) throws {
        let existing = try modelContext.fetch(FetchDescriptor<HostCommandSegmentRecord>(
            predicate: #Predicate { $0.hostID == hostID }
        ))
        for record in existing { modelContext.delete(record) }
        for (position, segment) in segments.enumerated() {
            modelContext.insert(HostCommandSegmentRecord(segment: segment, hostID: hostID, position: position))
        }
    }

    func activeSnippetScripts() throws -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: try listSnippets(includeDeleted: false).map { ($0.id, $0.script) })
    }

    func refreshConnectCommands(referencing snippetID: UUID) throws {
        let scripts = try activeSnippetScripts()
        let hosts = try modelContext.fetch(FetchDescriptor<HostRecord>())
        for record in hosts {
            let segments = try commandSegments(for: record.id)
            guard segments.contains(where: { $0.snippetID == snippetID }) else { continue }
            let rendered = ConnectCommandScript.render(segments, scripts: scripts)
            guard record.connectCommands != rendered else { continue }
            record.connectCommands = rendered
            record.updatedAt = .now
        }
    }
}
