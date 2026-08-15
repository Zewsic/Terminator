import Foundation
import TerminatorCore

/// Records side effects performed against SecretStore so a feature workflow
/// can compensate when its metadata transaction fails.
struct SecretMutationJournal {
    struct Backup: Sendable {
        let id: SecretID
        let data: Data
        let access: SecretAccessPolicy
    }

    let secretStore: any SecretStore
    private(set) var createdIDs: [SecretID] = []
    private(set) var removals: [SecretID] = []
    private(set) var backups: [Backup] = []
    private(set) var purgedIDs: Set<SecretID> = []

    mutating func create(
        _ data: Data,
        id: SecretID = SecretID(),
        access: SecretAccessPolicy = .deviceOnly
    ) async throws -> SecretID {
        try await secretStore.store(data, for: id, access: access)
        createdIDs.append(id)
        return id
    }

    mutating func removeAfterCommit(_ id: SecretID?) {
        guard let id, !removals.contains(id) else { return }
        removals.append(id)
    }

    mutating func backUp(_ ids: [SecretID], access: SecretAccessPolicy = .deviceOnly) async throws {
        backups = try await ids.asyncMap {
            Backup(id: $0, data: try await secretStore.read(id: $0), access: access)
        }
    }

    mutating func purgeBackedUpSecrets() async throws {
        for backup in backups {
            try await secretStore.purge(id: backup.id)
            purgedIDs.insert(backup.id)
        }
    }

    func commitRemovals() async {
        for id in removals {
            try? await secretStore.purge(id: id)
        }
    }

    func rollbackCreatedSecrets() async {
        for id in createdIDs.reversed() {
            try? await secretStore.purge(id: id)
        }
    }

    func restorePurgedSecrets() async {
        for backup in backups where purgedIDs.contains(backup.id) {
            try? await secretStore.store(backup.data, for: backup.id, access: backup.access)
        }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
