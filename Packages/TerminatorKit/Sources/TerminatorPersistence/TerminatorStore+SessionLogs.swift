import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
    public func listSessionLogs() throws -> [SessionLogMetadata] {
        try modelContext.fetch(FetchDescriptor<SessionLogRecord>())
            .map(\.domain)
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func sessionLog(id: UUID) throws -> SessionLogMetadata? {
        var descriptor = FetchDescriptor<SessionLogRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.domain
    }

    public func saveSessionLog(_ log: SessionLogMetadata) throws {
        var descriptor = FetchDescriptor<SessionLogRecord>(predicate: #Predicate { $0.id == log.id })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first { record.apply(log) }
        else { modelContext.insert(SessionLogRecord(log: log)) }
        try modelContext.save()
    }

    public func deleteSessionLog(id: UUID) throws {
        var descriptor = FetchDescriptor<SessionLogRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

}
