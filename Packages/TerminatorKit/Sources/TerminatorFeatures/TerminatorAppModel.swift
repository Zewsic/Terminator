import Foundation
import Observation
import TerminatorCore

@MainActor
@Observable
public final class TerminatorAppModel {
    public var selection: AppSection = .overview
    public private(set) var hosts: [HostProfile] = []
    public private(set) var credentials: [CredentialMetadata] = []
    public private(set) var history: [HistoryEntry] = []
    public private(set) var containers: [ContainerSummary] = []
    public private(set) var isLoading = false
    public var errorMessage: String?

    public let capabilities: AppCapabilities

    private let hostRepository: any HostRepository
    private let credentialRepository: any CredentialRepository
    private let historyRepository: any HistoryRepository
    private let secretStore: any SecretStore
    private let dockerService: any DockerService

    public init(
        capabilities: AppCapabilities,
        hostRepository: any HostRepository,
        credentialRepository: any CredentialRepository,
        historyRepository: any HistoryRepository,
        secretStore: any SecretStore,
        dockerService: any DockerService
    ) {
        self.capabilities = capabilities
        self.hostRepository = hostRepository
        self.credentialRepository = credentialRepository
        self.historyRepository = historyRepository
        self.secretStore = secretStore
        self.dockerService = dockerService
    }

    public var activeCredentials: [CredentialMetadata] {
        credentials.filter { !$0.isDeleted && $0.isSecretAvailable }
    }

    public var activeHosts: [HostProfile] { hosts.filter { !$0.isDeleted } }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            hosts = try await hostRepository.listHosts(includeDeleted: false)
            credentials = try await credentialRepository.listCredentials(includeDeleted: true)
            history = try await historyRepository.listHistory(entity: nil)
            containers = try await dockerService.listContainers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func saveHost(_ draft: HostDraft) async -> Bool {
        do {
            let existing = draft.id.flatMap { id in hosts.first(where: { $0.id == id }) }
            let now = Date.now
            let host = HostProfile(
                id: existing?.id ?? draft.id ?? UUID(),
                displayName: draft.displayName,
                hostname: draft.hostname,
                port: draft.port,
                username: draft.username,
                group: draft.group,
                tags: draft.tags,
                notes: draft.notes,
                credentialID: draft.credentialID,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                deletedAt: existing?.deletedAt
            )
            try await hostRepository.saveHost(host)
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func deleteHost(id: UUID) async {
        do {
            try await hostRepository.deleteHost(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func saveCredential(_ draft: CredentialDraft) async -> Bool {
        let trimmedSecret = draft.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty, let data = trimmedSecret.data(using: .utf8) else {
            errorMessage = CredentialValidationError.missingSecret.localizedDescription
            return false
        }

        let secretID = SecretID()
        do {
            try await secretStore.store(data, for: secretID)
            let credential = CredentialMetadata(
                label: draft.label,
                kind: draft.kind,
                secretID: secretID,
                fingerprint: draft.fingerprint
            )
            do {
                try await credentialRepository.saveCredential(credential)
            } catch {
                try? await secretStore.purge(id: secretID)
                throw error
            }
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func deleteCredential(id: UUID) async {
        guard credentialUsageCount(id: id) == 0 else {
            errorMessage = "Detach this credential from every host before archiving it."
            return
        }
        do {
            try await credentialRepository.deleteCredential(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Replaces a secret by allocating a new immutable Keychain item. The old item remains
    /// available until explicitly purged.
    public func replaceCredentialSecret(id: UUID, with secret: String) async -> Bool {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty,
              let data = trimmedSecret.data(using: .utf8),
              var credential = credentials.first(where: { $0.id == id }) else {
            errorMessage = CredentialValidationError.missingSecret.localizedDescription
            return false
        }

        let replacementID = SecretID()
        do {
            try await secretStore.store(data, for: replacementID)
            credential.secretID = replacementID
            credential.secretPurgedAt = nil
            do {
                try await credentialRepository.saveCredential(credential)
            } catch {
                try? await secretStore.purge(id: replacementID)
                throw error
            }
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func purgeCredential(id: UUID) async {
        guard credentialUsageCount(id: id) == 0,
              var credential = credentials.first(where: { $0.id == id }),
              credential.isSecretAvailable else {
            errorMessage = "Only an unused, available credential can be purged."
            return
        }
        do {
            try await secretStore.purge(id: credential.secretID)
            credential.secretPurgedAt = .now
            credential.deletedAt = credential.deletedAt ?? .now
            try await credentialRepository.saveCredential(credential)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func revert(historyEntryID: UUID) async {
        do {
            try await historyRepository.revert(historyEntryID: historyEntryID)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func credentialUsageCount(id: UUID) -> Int {
        hosts.count { $0.credentialID == id && !$0.isDeleted }
    }
}

public struct HostDraft: Identifiable, Equatable, Sendable {
    public var id: UUID?
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var group: String
    public var tagsText: String
    public var notes: String
    public var credentialID: UUID?

    public init(host: HostProfile? = nil) {
        id = host?.id
        displayName = host?.displayName ?? ""
        hostname = host?.hostname ?? ""
        port = host?.port ?? 22
        username = host?.username ?? ""
        group = host?.group ?? ""
        tagsText = host?.tags.joined(separator: ", ") ?? ""
        notes = host?.notes ?? ""
        credentialID = host?.credentialID
    }

    public var tags: [String] {
        tagsText.split(separator: ",").map(String.init)
    }
}

public struct CredentialDraft: Equatable, Sendable {
    public var label = ""
    public var kind: CredentialKind = .password
    public var secret = ""
    public var fingerprint = ""

    public init() {}
}
