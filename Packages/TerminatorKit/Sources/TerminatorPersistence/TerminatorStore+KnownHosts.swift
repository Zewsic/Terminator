import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
    public func knownHosts(endpoint: String) throws -> [KnownHostKey] {
        let descriptor = FetchDescriptor<KnownHostRecord>(predicate: #Predicate { $0.endpoint == endpoint })
        let records = try modelContext.fetch(descriptor)
        let needsMigration = records.contains { $0.lookupKey == nil }
        for record in records { record.populateLookupKeyIfNeeded() }
        if needsMigration { try modelContext.save() }
        return records.map(\.domain)
            .sorted { $0.algorithm < $1.algorithm }
    }

    public func saveKnownHost(_ key: KnownHostKey) throws {
        let algorithm = key.algorithm
        var descriptor = FetchDescriptor<KnownHostRecord>(
            predicate: #Predicate { $0.endpoint == key.endpoint && $0.algorithm == algorithm }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first { record.apply(key) }
        else { modelContext.insert(KnownHostRecord(key: key)) }
        try modelContext.save()
    }

    public func removeKnownHost(endpoint: String, algorithm: String?) throws {
        let records = try modelContext.fetch(
            FetchDescriptor<KnownHostRecord>(predicate: #Predicate { $0.endpoint == endpoint })
        )
        for record in records where algorithm == nil || record.algorithm == algorithm {
            modelContext.delete(record)
        }
        if !records.isEmpty { try modelContext.save() }
    }

}
