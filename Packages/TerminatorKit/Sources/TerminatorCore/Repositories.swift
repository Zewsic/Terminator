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

public protocol HistoryRepository: Sendable {
    func listHistory(entity: HistoryEntity?) async throws -> [HistoryEntry]
    func revert(historyEntryID: UUID) async throws
}

public protocol SecretStore: Sendable {
    func store(_ secret: Data, for id: SecretID) async throws
    func read(id: SecretID) async throws -> Data
    func purge(id: SecretID) async throws
}
