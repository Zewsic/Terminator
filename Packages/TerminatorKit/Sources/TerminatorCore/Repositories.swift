import Foundation

public protocol HostRepository: Sendable {
    func listHosts(includeDeleted: Bool) async throws -> [HostProfile]
    func host(id: UUID) async throws -> HostProfile?
    func saveHost(_ host: HostProfile) async throws
    func deleteHost(id: UUID) async throws
    func restoreHost(id: UUID) async throws
}

public protocol CredentialRepository: Sendable {
    func listCredentials(includeDeleted: Bool) async throws -> [CredentialMetadata]
    func credential(id: UUID) async throws -> CredentialMetadata?
    func saveCredential(_ credential: CredentialMetadata) async throws
    func deleteCredential(id: UUID) async throws
}

public protocol IdentityRepository: Sendable {
    func listIdentities(includeDeleted: Bool) async throws -> [IdentityProfile]
    func identity(id: UUID) async throws -> IdentityProfile?
    func saveIdentity(_ identity: IdentityProfile) async throws
    func deleteIdentity(id: UUID) async throws
    func restoreIdentity(id: UUID) async throws
}

public protocol HistoryRepository: Sendable {
    func listHistory(entity: HistoryEntity?) async throws -> [HistoryEntry]
    func revert(historyEntryID: UUID) async throws
}

public enum SecretAccessPolicy: Equatable, Sendable {
    case deviceOnly
    case userPresence
}

public protocol SecretStore: Sendable {
    func store(_ secret: Data, for id: SecretID, access: SecretAccessPolicy) async throws
    func read(id: SecretID) async throws -> Data
    func purge(id: SecretID) async throws
}

public extension SecretStore {
    func store(_ secret: Data, for id: SecretID) async throws {
        try await store(secret, for: id, access: .deviceOnly)
    }
}

public protocol KnownHostRepository: Sendable {
    func knownHosts(endpoint: String) async throws -> [KnownHostKey]
    func saveKnownHost(_ key: KnownHostKey) async throws
    func removeKnownHost(endpoint: String, algorithm: String?) async throws
}

public extension KnownHostRepository {
    func knownHost(endpoint: String, algorithm: String? = nil) async throws -> KnownHostKey? {
        let keys = try await knownHosts(endpoint: endpoint)
        guard let algorithm else { return keys.first }
        return keys.first { $0.algorithm == algorithm }
    }

    func removeKnownHost(endpoint: String) async throws {
        try await removeKnownHost(endpoint: endpoint, algorithm: nil)
    }
}

public protocol TunnelRepository: Sendable {
    func listTunnels(includeDeleted: Bool) async throws -> [TunnelProfile]
    func tunnel(id: UUID) async throws -> TunnelProfile?
    func saveTunnel(_ tunnel: TunnelProfile) async throws
    func deleteTunnel(id: UUID) async throws
}

public protocol SessionLogRepository: Sendable {
    func listSessionLogs() async throws -> [SessionLogMetadata]
    func sessionLog(id: UUID) async throws -> SessionLogMetadata?
    func saveSessionLog(_ log: SessionLogMetadata) async throws
    func deleteSessionLog(id: UUID) async throws
}
