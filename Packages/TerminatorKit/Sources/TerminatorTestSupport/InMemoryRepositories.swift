import Foundation
import TerminatorCore

public actor InMemoryTerminatorStore: HostRepository, CredentialRepository, IdentityRepository, HistoryRepository, KnownHostRepository, SessionLogRepository, TunnelRepository, SnippetRepository {
    private var hosts: [UUID: HostProfile]
    private var credentials: [UUID: CredentialMetadata]
    private var identities: [UUID: IdentityProfile]
    private var tunnels: [UUID: TunnelProfile]
    private var history: [HistoryEntry]
    private var knownHosts: [String: KnownHostKey]
    private var sessionLogs: [UUID: SessionLogMetadata]
    private var snippets: [UUID: SnippetProfile]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        hosts: [HostProfile] = [],
        credentials: [CredentialMetadata] = [],
        identities: [IdentityProfile] = [],
        history: [HistoryEntry] = [],
        knownHosts: [KnownHostKey] = [],
        sessionLogs: [SessionLogMetadata] = []
    ) {
        self.hosts = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        self.tunnels = [:]
        self.credentials = Dictionary(uniqueKeysWithValues: credentials.map { ($0.id, $0) })
        self.identities = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0) })
        self.history = history
        self.knownHosts = Dictionary(uniqueKeysWithValues: knownHosts.map { (Self.knownHostKey($0.endpoint, $0.algorithm), $0) })
        self.sessionLogs = Dictionary(uniqueKeysWithValues: sessionLogs.map { ($0.id, $0) })
        self.snippets = [:]
    }

    public func listHosts(includeDeleted: Bool) -> [HostProfile] {
        hosts.values
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.displayName < $1.displayName }
    }

    public func host(id: UUID) -> HostProfile? { hosts[id] }

    public func saveHost(_ host: HostProfile) throws {
        var host = try host.validated()
        let incomingSegments = host.connectCommandSegments
        host.connectCommandSegments = ConnectCommandScript.stored(incomingSegments)
        if !incomingSegments.isEmpty {
            let scripts = Dictionary(uniqueKeysWithValues: snippets.values.filter { !$0.isDeleted }.map { ($0.id, $0.script) })
            host.connectCommands = ConnectCommandScript.render(host.connectCommandSegments, scripts: scripts)
        }
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

    public func purgeHost(id: UUID) throws {
        guard let before = hosts[id] else { return }
        hosts[id] = nil
        history.append(try entry(entity: .host, id: id, operation: .purged, before: before, after: nil as HostProfile?))
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

    public func listIdentities(includeDeleted: Bool) -> [IdentityProfile] {
        identities.values
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.name < $1.name }
    }

    public func identity(id: UUID) -> IdentityProfile? { identities[id] }

    public func saveIdentity(_ identity: IdentityProfile) throws {
        let identity = try identity.validated()
        let before = identities[identity.id]
        identities[identity.id] = identity
        history.append(try entry(entity: .identity, id: identity.id, operation: before == nil ? .created : .updated, before: before, after: identity))
    }

    public func deleteIdentity(id: UUID) throws {
        guard let before = identities[id] else { return }
        var after = before
        after.deletedAt = .now
        identities[id] = after
        history.append(try entry(entity: .identity, id: id, operation: .deleted, before: before, after: after))
    }

    public func restoreIdentity(id: UUID) throws {
        guard let before = identities[id] else { return }
        var after = before
        after.deletedAt = nil
        identities[id] = after
        history.append(try entry(entity: .identity, id: id, operation: .restored, before: before, after: after))
    }

    public func purgeIdentity(id: UUID) throws {
        guard let before = identities[id] else { return }
        identities[id] = nil
        history.append(try entry(entity: .identity, id: id, operation: .purged, before: before, after: nil as IdentityProfile?))
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
                var target = try decoder.decode(HostProfile.self, from: snapshot)
                if case .manual(let username, let targetMethods) = target.authentication {
                    target.authentication = .manual(
                        username: username,
                        authenticationMethods: preservingCurrentPassword(
                            in: targetMethods,
                            currentMethods: before?.authentication.authenticationMethods ?? []
                        )
                    )
                }
                hosts[change.entityID] = target
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
        case .identity:
            let before = identities[change.entityID]
            if let snapshot = change.beforeSnapshot {
                var target = try decoder.decode(IdentityProfile.self, from: snapshot)
                target.authenticationMethods = preservingCurrentPassword(
                    in: target.authenticationMethods,
                    currentMethods: before?.authenticationMethods ?? []
                )
                identities[change.entityID] = target
            } else if var current = before {
                current.deletedAt = .now
                identities[change.entityID] = current
            }
            history.append(try entry(entity: .identity, id: change.entityID, operation: .restored, before: before, after: identities[change.entityID]))
        case .snippet:
            let before = snippets[change.entityID]
            if let snapshot = change.beforeSnapshot {
                snippets[change.entityID] = try decoder.decode(SnippetProfile.self, from: snapshot)
            } else if var current = before {
                current.deletedAt = .now
                snippets[change.entityID] = current
            }
            refreshConnectCommands(referencing: change.entityID)
            history.append(try entry(entity: .snippet, id: change.entityID, operation: .restored, before: before, after: snippets[change.entityID]))
        case .tunnel:
            let before = tunnels[change.entityID]
            if let snapshot = change.beforeSnapshot {
                tunnels[change.entityID] = try decoder.decode(TunnelProfile.self, from: snapshot)
            } else if var current = before {
                current.deletedAt = .now
                tunnels[change.entityID] = current
            }
            history.append(try entry(entity: .tunnel, id: change.entityID, operation: .restored, before: before, after: tunnels[change.entityID]))
        }
    }

    public func listTunnels(includeDeleted: Bool) -> [TunnelProfile] {
        tunnels.values
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.displayName < $1.displayName }
    }

    public func tunnel(id: UUID) -> TunnelProfile? { tunnels[id] }

    public func saveTunnel(_ tunnel: TunnelProfile) throws {
        let tunnel = try tunnel.validated()
        let before = tunnels[tunnel.id]
        tunnels[tunnel.id] = tunnel
        history.append(try entry(entity: .tunnel, id: tunnel.id, operation: before == nil ? .created : .updated, before: before, after: tunnel))
    }

    public func deleteTunnel(id: UUID) throws {
        guard let before = tunnels[id] else { return }
        var after = before
        after.deletedAt = .now
        tunnels[id] = after
        history.append(try entry(entity: .tunnel, id: id, operation: .deleted, before: before, after: after))
    }

    public func restoreTunnel(id: UUID) throws {
        guard let before = tunnels[id] else { return }
        var after = before
        after.deletedAt = nil
        tunnels[id] = after
        history.append(try entry(entity: .tunnel, id: id, operation: .restored, before: before, after: after))
    }

    public func purgeTunnel(id: UUID) throws {
        guard let before = tunnels[id] else { return }
        tunnels[id] = nil
        history.append(try entry(entity: .tunnel, id: id, operation: .purged, before: before, after: nil as TunnelProfile?))
    }

    public func knownHosts(endpoint: String) -> [KnownHostKey] {
        knownHosts.values.filter { $0.endpoint == endpoint }.sorted { $0.algorithm < $1.algorithm }
    }
    public func saveKnownHost(_ key: KnownHostKey) {
        knownHosts[Self.knownHostKey(key.endpoint, key.algorithm)] = key
    }
    public func removeKnownHost(endpoint: String, algorithm: String?) {
        knownHosts = knownHosts.filter { _, key in
            key.endpoint != endpoint || (algorithm != nil && key.algorithm != algorithm)
        }
    }

    public func listSnippets(includeDeleted: Bool) -> [SnippetProfile] {
        snippets.values
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.name < $1.name }
    }

    public func snippet(id: UUID) -> SnippetProfile? { snippets[id] }

    public func saveSnippet(_ snippet: SnippetProfile) throws {
        let snippet = try snippet.validated()
        let before = snippets[snippet.id]
        snippets[snippet.id] = snippet
        history.append(try entry(entity: .snippet, id: snippet.id, operation: before == nil ? .created : .updated, before: before, after: snippet))
        refreshConnectCommands(referencing: snippet.id)
    }

    public func deleteSnippet(id: UUID) throws {
        guard var after = snippets[id] else { return }
        let before = after
        after.deletedAt = .now
        snippets[id] = after
        history.append(try entry(entity: .snippet, id: id, operation: .deleted, before: before, after: after))
        refreshConnectCommands(referencing: id)
    }

    public func restoreSnippet(id: UUID) throws {
        guard var after = snippets[id] else { return }
        let before = after
        after.deletedAt = nil
        snippets[id] = after
        history.append(try entry(entity: .snippet, id: id, operation: .restored, before: before, after: after))
        refreshConnectCommands(referencing: id)
    }

    public func purgeSnippet(id: UUID) throws {
        guard let before = snippets[id] else { return }
        snippets[id] = nil
        history.append(try entry(entity: .snippet, id: id, operation: .purged, before: before, after: nil as SnippetProfile?))
        refreshConnectCommands(referencing: id)
    }

    public func noteSnippetUsed(id: UUID) {
        guard var snippet = snippets[id] else { return }
        snippet.lastUsedAt = .now
        snippets[id] = snippet
    }

    public func importSnippet(_ snippet: SnippetProfile) throws {
        let snippet = try snippet.validated()
        if let externalID = snippet.externalID, let existing = snippets.values.first(where: { $0.externalID == externalID }) {
            var merged = snippet
            merged.id = existing.id
            merged.createdAt = existing.createdAt
            merged.lastUsedAt = existing.lastUsedAt
            merged.deletedAt = existing.deletedAt
            try saveSnippet(merged)
            return
        }
        try saveSnippet(snippet)
    }

    private func refreshConnectCommands(referencing snippetID: UUID) {
        let scripts = Dictionary(uniqueKeysWithValues: snippets.values.filter { !$0.isDeleted }.map { ($0.id, $0.script) })
        for (id, host) in hosts where host.connectCommandSegments.contains(where: { $0.snippetID == snippetID }) {
            var updated = host
            updated.connectCommands = ConnectCommandScript.render(updated.connectCommandSegments, scripts: scripts)
            updated.updatedAt = .now
            hosts[id] = updated
        }
    }

    public func listSessionLogs() -> [SessionLogMetadata] {
        sessionLogs.values.sorted { $0.startedAt > $1.startedAt }
    }
    public func sessionLog(id: UUID) -> SessionLogMetadata? { sessionLogs[id] }
    public func saveSessionLog(_ log: SessionLogMetadata) { sessionLogs[log.id] = log }
    public func deleteSessionLog(id: UUID) { sessionLogs[id] = nil }

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

    private func preservingCurrentPassword(
        in historicalMethods: [AuthenticationMethod],
        currentMethods: [AuthenticationMethod]
    ) -> [AuthenticationMethod] {
        var methods = historicalMethods.filter { $0.passwordSecretID == nil }
        guard let currentPassword = currentMethods.first(where: { $0.passwordSecretID != nil }) else {
            return methods
        }
        let historicalIndex = historicalMethods.firstIndex(where: { $0.passwordSecretID != nil }) ?? 0
        methods.insert(currentPassword, at: min(historicalIndex, methods.count))
        return methods
    }

    private static func knownHostKey(_ endpoint: String, _ algorithm: String) -> String {
        endpoint.lowercased() + "\u{1f}" + algorithm.lowercased()
    }
}

public actor InMemorySecretStore: SecretStore {
    private var values: [SecretID: Data] = [:]
    private var accessPolicies: [SecretID: SecretAccessPolicy] = [:]

    public init() {}

    public func store(_ secret: Data, for id: SecretID, access: SecretAccessPolicy) throws {
        guard values[id] == nil else { throw InMemorySecretError.duplicate }
        values[id] = secret
        accessPolicies[id] = access
    }

    public func read(id: SecretID) throws -> Data {
        guard let value = values[id] else { throw InMemorySecretError.notFound }
        return value
    }

    public func accessPolicy(id: SecretID) -> SecretAccessPolicy? { accessPolicies[id] }

    public func purge(id: SecretID) {
        values[id] = nil
        accessPolicies[id] = nil
    }
}

public enum InMemorySecretError: Error, Sendable {
    case duplicate
    case notFound
}
