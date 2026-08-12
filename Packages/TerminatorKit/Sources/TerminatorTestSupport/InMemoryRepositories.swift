import Foundation
import TerminatorCore

public actor InMemoryTerminatorStore: HostRepository, CredentialRepository, HistoryRepository {
    private var hosts: [UUID: HostProfile]
    private var credentials: [UUID: CredentialMetadata]
    private var history: [HistoryEntry]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        hosts: [HostProfile] = [],
        credentials: [CredentialMetadata] = [],
        history: [HistoryEntry] = []
    ) {
        self.hosts = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        self.credentials = Dictionary(uniqueKeysWithValues: credentials.map { ($0.id, $0) })
        self.history = history
    }

    public func listHosts(includeDeleted: Bool) -> [HostProfile] {
        hosts.values
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.displayName < $1.displayName }
    }

    public func host(id: UUID) -> HostProfile? { hosts[id] }

    public func saveHost(_ host: HostProfile) throws {
        let host = try host.validated()
        let before = hosts[host.id]
        hosts[host.id] = host
        history.append(try entry(entity: .host, id: host.id, operation: before == nil ? .created : .updated, before: before, after: host))
    }

    public func deleteHost(id: UUID) throws {
        guard let before = hosts[id] else { return }
        var after = before
        after.deletedAt = .now
        hosts[id] = after
        history.append(try entry(entity: .host, id: id, operation: .deleted, before: before, after: after))
    }

    public func restoreHost(id: UUID) throws {
        guard let before = hosts[id] else { return }
        var after = before
        after.deletedAt = nil
        hosts[id] = after
        history.append(try entry(entity: .host, id: id, operation: .restored, before: before, after: after))
    }

    public func listCredentials(includeDeleted: Bool) -> [CredentialMetadata] {
        credentials.values
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.label < $1.label }
    }

    public func credential(id: UUID) -> CredentialMetadata? { credentials[id] }

    public func saveCredential(_ credential: CredentialMetadata) throws {
        let credential = try credential.validated()
        let before = credentials[credential.id]
        credentials[credential.id] = credential
        let operation: HistoryOperation = before == nil ? .created : .updated
        history.append(try entry(entity: .credential, id: credential.id, operation: operation, before: before, after: credential))
    }

    public func deleteCredential(id: UUID) throws {
        guard let before = credentials[id] else { return }
        var after = before
        after.deletedAt = .now
        credentials[id] = after
        history.append(try entry(entity: .credential, id: id, operation: .deleted, before: before, after: after))
    }

    public func listHistory(entity: HistoryEntity?) -> [HistoryEntry] {
        history.filter { entity == nil || $0.entity == entity }.sorted { $0.timestamp > $1.timestamp }
    }

    public func revert(historyEntryID: UUID) throws {
        guard let change = history.first(where: { $0.id == historyEntryID }) else { return }
        switch change.entity {
        case .host:
            let before = hosts[change.entityID]
            if let snapshot = change.beforeSnapshot {
                hosts[change.entityID] = try decoder.decode(HostProfile.self, from: snapshot)
            } else if var current = before {
                current.deletedAt = .now
                hosts[change.entityID] = current
            }
            history.append(try entry(entity: .host, id: change.entityID, operation: .restored, before: before, after: hosts[change.entityID]))
        case .credential:
            let before = credentials[change.entityID]
            if let snapshot = change.beforeSnapshot {
                credentials[change.entityID] = try decoder.decode(CredentialMetadata.self, from: snapshot)
            } else if var current = before {
                current.deletedAt = .now
                credentials[change.entityID] = current
            }
            history.append(try entry(entity: .credential, id: change.entityID, operation: .restored, before: before, after: credentials[change.entityID]))
        }
    }

    private func entry<Value: Encodable>(
        entity: HistoryEntity,
        id: UUID,
        operation: HistoryOperation,
        before: Value?,
        after: Value?
    ) throws -> HistoryEntry {
        HistoryEntry(
            entity: entity,
            entityID: id,
            operation: operation,
            beforeSnapshot: try before.map(encoder.encode),
            afterSnapshot: try after.map(encoder.encode)
        )
    }
}

public actor InMemorySecretStore: SecretStore {
    private var values: [SecretID: Data] = [:]

    public init() {}

    public func store(_ secret: Data, for id: SecretID) throws {
        guard values[id] == nil else { throw InMemorySecretError.duplicate }
        values[id] = secret
    }

    public func read(id: SecretID) throws -> Data {
        guard let value = values[id] else { throw InMemorySecretError.notFound }
        return value
    }

    public func purge(id: SecretID) { values[id] = nil }
}

public enum InMemorySecretError: Error, Sendable {
    case duplicate
    case notFound
}
