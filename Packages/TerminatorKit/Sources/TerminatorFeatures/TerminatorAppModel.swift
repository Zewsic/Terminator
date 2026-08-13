import Foundation
import Observation
import TerminatorCore

@MainActor
@Observable
public final class TerminatorAppModel {
    public var selection: AppSection = .overview
    public private(set) var hosts: [HostProfile] = []
    public private(set) var credentials: [CredentialMetadata] = []
    public private(set) var identities: [IdentityProfile] = []
    public private(set) var history: [HistoryEntry] = []
    public private(set) var containers: [ContainerSummary] = []
    public private(set) var isLoading = false
    public var errorMessage: String?

    public let capabilities: AppCapabilities

    private let hostRepository: any HostRepository
    private let credentialRepository: any CredentialRepository
    private let identityRepository: any IdentityRepository
    private let historyRepository: any HistoryRepository
    private let secretStore: any SecretStore
    private let accessKeyService: any AccessKeyService
    private let userPresenceAuthorizer: any UserPresenceAuthorizer
    private let dockerService: any DockerService

    public init(
        capabilities: AppCapabilities,
        hostRepository: any HostRepository,
        credentialRepository: any CredentialRepository,
        identityRepository: any IdentityRepository,
        historyRepository: any HistoryRepository,
        secretStore: any SecretStore,
        accessKeyService: any AccessKeyService,
        userPresenceAuthorizer: any UserPresenceAuthorizer,
        dockerService: any DockerService
    ) {
        self.capabilities = capabilities
        self.hostRepository = hostRepository
        self.credentialRepository = credentialRepository
        self.identityRepository = identityRepository
        self.historyRepository = historyRepository
        self.secretStore = secretStore
        self.accessKeyService = accessKeyService
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.dockerService = dockerService
    }

    public var activeCredentials: [CredentialMetadata] {
        credentials.filter { !$0.isDeleted && $0.isSecretAvailable && $0.kind == .accessKey }
    }

    public var activeIdentities: [IdentityProfile] { identities.filter { !$0.isDeleted } }
    public var activeHosts: [HostProfile] { hosts.filter { !$0.isDeleted } }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            hosts = try await hostRepository.listHosts(includeDeleted: false)
            credentials = try await credentialRepository.listCredentials(includeDeleted: true)
            identities = try await identityRepository.listIdentities(includeDeleted: true)
            history = try await historyRepository.listHistory(entity: nil)
            containers = try await dockerService.listContainers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func saveHost(_ draft: HostDraft) async -> Bool {
        var newPasswordID: SecretID?
        do {
            let existing = draft.id.flatMap { id in hosts.first(where: { $0.id == id }) }
            let now = Date.now
            let authentication: HostAuthentication
            if draft.usesIdentity, let identityID = draft.identityID {
                authentication = .identity(identityID)
            } else {
                var methods: [AuthenticationMethod] = []
                for method in draft.authenticationMethods {
                    switch method.kind {
                    case .accessKey(let credentialID):
                        methods.append(.accessKey(credentialID: credentialID))
                    case .password(let existingSecretID):
                        let value = method.password.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty {
                            let secretID = SecretID()
                            try await secretStore.store(Data(value.utf8), for: secretID)
                            newPasswordID = secretID
                            methods.append(.password(secretID: secretID))
                        } else if let existingSecretID {
                            methods.append(.password(secretID: existingSecretID))
                        } else {
                            throw CredentialValidationError.missingSecret
                        }
                    }
                }
                authentication = .manual(username: draft.username, authenticationMethods: methods)
            }
            let host = HostProfile(
                id: existing?.id ?? draft.id ?? UUID(),
                displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? draft.hostname
                    : draft.displayName,
                hostname: draft.hostname,
                port: draft.port,
                authentication: authentication,
                group: draft.group,
                tags: draft.tags,
                notes: draft.notes,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                deletedAt: existing?.deletedAt
            )
            do { try await hostRepository.saveHost(host) }
            catch {
                if let newPasswordID { try? await secretStore.purge(id: newPasswordID) }
                throw error
            }
            await load()
            return true
        } catch {
            if let newPasswordID { try? await secretStore.purge(id: newPasswordID) }
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func deleteHost(id: UUID) async {
        do {
            try await hostRepository.deleteHost(id: id)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func saveAccessKey(_ draft: AccessKeyDraft) async -> UUID? {
        if draft.credentialID != nil {
            return await replaceAccessKey(draft) ? draft.credentialID : nil
        }
        guard draft.passphrase == draft.passphraseConfirmation else {
            errorMessage = "Passphrases do not match."
            return nil
        }
        do {
            let label = resolvedAccessKeyLabel(for: draft)
            let prepared: PreparedAccessKey
            let origin: AccessKeyOrigin
            switch draft.mode {
            case .importExisting:
                prepared = try await accessKeyService.importSoftwareKey(AccessKeyImportRequest(
                    privateKey: draft.privateKey,
                    suppliedPublicKey: draft.publicKey,
                    passphrase: draft.passphrase
                ))
                origin = .imported
            case .generateSoftware:
                prepared = try await accessKeyService.generateSoftwareKey(AccessKeyGenerationRequest(
                    algorithm: draft.generation,
                    comment: draft.comment,
                    passphrase: draft.passphrase
                ))
                origin = .generated
            case .generateSecureEnclave:
                prepared = try await accessKeyService.generateSecureEnclaveKey(label: label)
                origin = .generated
            }

            if prepared.compatibility == .legacyRSA1024, !draft.acceptLegacyRSA1024 {
                throw AccessKeyImportPolicyError.legacyRSAConfirmationRequired
            }

            let privateID = SecretID()
            var storedIDs = [privateID]
            try await secretStore.store(prepared.privateMaterial, for: privateID)
            var protection: PassphraseProtection = prepared.isPassphraseProtected ? .promptEveryConnection : .none
            if prepared.isPassphraseProtected, draft.savePassphrase, !draft.passphrase.isEmpty,
               let data = draft.passphrase.data(using: .utf8) {
                let passphraseID = SecretID()
                do { try await secretStore.store(data, for: passphraseID) }
                catch {
                    try? await secretStore.purge(id: privateID)
                    throw error
                }
                storedIDs.append(passphraseID)
                protection = .saved(secretID: passphraseID)
            }

            let key = AccessKeyMetadata(
                algorithm: prepared.algorithm,
                backend: prepared.backend,
                origin: origin,
                publicKey: prepared.publicKey,
                fingerprint: prepared.fingerprint,
                privateMaterialID: privateID,
                passphraseProtection: protection,
                compatibility: prepared.compatibility
            )
            let credential = CredentialMetadata(
                label: label,
                kind: .accessKey,
                secretID: privateID,
                accessKey: key
            )
            do { try await credentialRepository.saveCredential(credential) }
            catch {
                for id in storedIDs { try? await secretStore.purge(id: id) }
                throw error
            }
            await load()
            return credential.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func accessKeyDraft(id: UUID, unlockingWith suppliedPassphrase: String = "") async -> AccessKeyDraft? {
        guard let credential = credentials.first(where: { $0.id == id }),
              let key = credential.accessKey else { return nil }

        var draft = AccessKeyDraft()
        draft.credentialID = id
        draft.label = credential.label
        draft.mode = key.backend == .secureEnclave ? .generateSecureEnclave : .importExisting
        draft.publicKey = key.publicKey
        draft.originalAlgorithm = key.algorithm
        draft.acceptLegacyRSA1024 = key.compatibility == .legacyRSA1024

        guard key.backend == .software, credential.isSecretAvailable else { return draft }
        do {
            let passphrase: String
            switch key.passphraseProtection {
            case .none:
                passphrase = ""
            case .saved(let secretID):
                let data = try await secretStore.read(id: secretID)
                guard let value = String(data: data, encoding: .utf8) else {
                    throw AccessKeyServiceError.invalidPassphrase
                }
                passphrase = value
                draft.savePassphrase = true
            case .promptEveryConnection:
                guard !suppliedPassphrase.isEmpty else {
                    draft.requiresUnlock = true
                    return draft
                }
                passphrase = suppliedPassphrase
            }
            try await userPresenceAuthorizer.authorize(reason: "Reveal SSH private key “\(credential.label)”")
            let material = try await secretStore.read(id: key.privateMaterialID)
            let clear = try await accessKeyService.exportSoftwareKey(
                privateMaterial: material,
                passphrase: passphrase
            )
            guard let privateKey = String(data: clear, encoding: .utf8) else {
                throw AccessKeyServiceError.invalidPrivateKey
            }
            draft.privateKey = privateKey
            draft.passphrase = passphrase
            draft.passphraseConfirmation = passphrase
            draft.requiresUnlock = false
            return draft
        } catch {
            errorMessage = error.localizedDescription
            return draft
        }
    }

    public func replaceAccessKey(_ draft: AccessKeyDraft) async -> Bool {
        guard let id = draft.credentialID,
              var credential = credentials.first(where: { $0.id == id }),
              let current = credential.accessKey else { return false }
        if current.backend == .secureEnclave {
            do {
                credential.label = resolvedAccessKeyLabel(for: draft)
                try await credentialRepository.saveCredential(credential)
                await load()
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        guard draft.passphrase == draft.passphraseConfirmation else {
            errorMessage = "Passphrases do not match."
            return false
        }
        guard !draft.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Load or unlock the private key before saving."
            return false
        }

        do {
            let prepared = try await accessKeyService.importSoftwareKey(.init(
                privateKey: draft.privateKey,
                suppliedPublicKey: draft.publicKey,
                passphrase: draft.passphrase
            ))
            if prepared.compatibility == .legacyRSA1024, !draft.acceptLegacyRSA1024 {
                throw AccessKeyImportPolicyError.legacyRSAConfirmationRequired
            }

            let privateID = SecretID()
            var newItems: [(SecretID, Data)] = [(privateID, prepared.privateMaterial)]
            var protection: PassphraseProtection = prepared.isPassphraseProtected ? .promptEveryConnection : .none
            if prepared.isPassphraseProtected, draft.savePassphrase,
               let data = draft.passphrase.data(using: .utf8), !data.isEmpty {
                let passphraseID = SecretID()
                newItems.append((passphraseID, data))
                protection = .saved(secretID: passphraseID)
            }

            var stored: [SecretID] = []
            do {
                for (secretID, data) in newItems {
                    try await secretStore.store(data, for: secretID)
                    stored.append(secretID)
                }
            } catch {
                for secretID in stored { try? await secretStore.purge(id: secretID) }
                throw error
            }

            credential.label = resolvedAccessKeyLabel(for: draft)
            credential.secretID = privateID
            credential.secretPurgedAt = nil
            credential.accessKey = AccessKeyMetadata(
                algorithm: prepared.algorithm,
                backend: .software,
                origin: .imported,
                publicKey: prepared.publicKey,
                fingerprint: prepared.fingerprint,
                privateMaterialID: privateID,
                passphraseProtection: protection,
                compatibility: prepared.compatibility
            )
            do {
                try await credentialRepository.saveCredential(credential)
            } catch {
                for secretID in stored { try? await secretStore.purge(id: secretID) }
                throw error
            }
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func exportPrivateKey(id: UUID, passphrase suppliedPassphrase: String = "") async -> Data? {
        guard let credential = credentials.first(where: { $0.id == id }),
              credential.kind == .accessKey,
              let key = credential.accessKey else { return nil }
        guard key.backend == .software else {
            errorMessage = AccessKeyServiceError.secureEnclaveKeyIsNotExportable.localizedDescription
            return nil
        }
        do {
            try await userPresenceAuthorizer.authorize(reason: "Export SSH private key “\(credential.label)”")
            let material = try await secretStore.read(id: key.privateMaterialID)
            let passphrase: String
            switch key.passphraseProtection {
            case .none:
                passphrase = ""
            case .promptEveryConnection:
                guard !suppliedPassphrase.isEmpty else { throw AccessKeyServiceError.passphraseRequired }
                passphrase = suppliedPassphrase
            case .saved(let secretID):
                let data = try await secretStore.read(id: secretID)
                guard let value = String(data: data, encoding: .utf8) else {
                    throw AccessKeyServiceError.invalidPassphrase
                }
                passphrase = value
            }
            return try await accessKeyService.exportSoftwareKey(privateMaterial: material, passphrase: passphrase)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func resolvedAccessKeyLabel(for draft: AccessKeyDraft) -> String {
        let explicit = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard explicit.isEmpty else { return explicit }
        let ordinal = draft.suggestedOrdinal ?? (
            credentials.filter { $0.kind == .accessKey && $0.id != draft.credentialID }.count + 1
        )
        let context = draft.suggestedLabelContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context, !context.isEmpty else { return "Key #\(ordinal)" }
        return "Key #\(ordinal) for “\(context)”"
    }

    public func saveIdentity(_ draft: IdentityDraft) async -> Bool {
        var newPasswordID: SecretID?
        do {
            let existing = draft.id.flatMap { id in identities.first(where: { $0.id == id }) }
            let now = Date.now
            var methods: [AuthenticationMethod] = []
            for method in draft.authenticationMethods {
                switch method.kind {
                case .accessKey(let credentialID):
                    methods.append(.accessKey(credentialID: credentialID))
                case .password(let existingSecretID):
                    let value = method.password.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        let secretID = SecretID()
                        guard let data = value.data(using: .utf8) else {
                            throw CredentialValidationError.missingSecret
                        }
                        try await secretStore.store(data, for: secretID)
                        newPasswordID = secretID
                        methods.append(.password(secretID: secretID))
                    } else if let existingSecretID {
                        methods.append(.password(secretID: existingSecretID))
                    } else {
                        throw CredentialValidationError.missingSecret
                    }
                }
            }
            let identity = IdentityProfile(
                id: existing?.id ?? draft.id ?? UUID(),
                name: draft.name,
                username: draft.username,
                authenticationMethods: methods,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                deletedAt: existing?.deletedAt
            )
            do { try await identityRepository.saveIdentity(identity) }
            catch {
                if let newPasswordID { try? await secretStore.purge(id: newPasswordID) }
                throw error
            }
            await load()
            return true
        } catch {
            if let newPasswordID { try? await secretStore.purge(id: newPasswordID) }
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func deleteIdentity(id: UUID) async {
        guard identityUsageCount(id: id) == 0 else {
            errorMessage = IdentityValidationError.identityInUse.localizedDescription
            return
        }
        do {
            try await identityRepository.deleteIdentity(id: id)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func deleteCredential(id: UUID) async {
        guard credentialUsageCount(id: id) == 0 else {
            errorMessage = "Detach this credential from every identity and host before archiving it."
            return
        }
        do {
            try await credentialRepository.deleteCredential(id: id)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func purgeCredential(id: UUID) async {
        guard credentialUsageCount(id: id) == 0,
              var credential = credentials.first(where: { $0.id == id }),
              credential.isSecretAvailable else {
            errorMessage = "Only an unused, available credential can be purged."
            return
        }
        do {
            let secretIDs = credential.allSecretIDs
            var backup: [(SecretID, Data)] = []
            for secretID in secretIDs {
                backup.append((secretID, try await secretStore.read(id: secretID)))
            }

            var purged: [SecretID] = []
            do {
                for secretID in secretIDs {
                    try await secretStore.purge(id: secretID)
                    purged.append(secretID)
                }
            } catch {
                for (secretID, data) in backup where purged.contains(secretID) {
                    try? await secretStore.store(data, for: secretID)
                }
                throw error
            }

            credential.secretPurgedAt = .now
            credential.deletedAt = credential.deletedAt ?? .now
            do {
                try await credentialRepository.saveCredential(credential)
            } catch {
                for (secretID, data) in backup {
                    try? await secretStore.store(data, for: secretID)
                }
                throw error
            }
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func revert(historyEntryID: UUID) async {
        do {
            try await historyRepository.revert(historyEntryID: historyEntryID)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func credentialUsageCount(id: UUID) -> Int {
        hosts.count { !$0.isDeleted && $0.authentication.credentialIDs.contains(id) }
            + identities.count { !$0.isDeleted && $0.credentialIDs.contains(id) }
    }

    public func identityUsageCount(id: UUID) -> Int {
        hosts.count { !$0.isDeleted && $0.authentication.identityID == id }
    }
}

public struct HostDraft: Identifiable, Equatable, Sendable {
    public var id: UUID?
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var usesIdentity: Bool
    public var identityID: UUID?
    public var username: String
    public var authenticationMethods: [IdentityDraftMethod]
    public var group: String
    public var tagsText: String
    public var notes: String

    public init(host: HostProfile? = nil) {
        id = host?.id
        displayName = host?.displayName ?? ""
        hostname = host?.hostname ?? ""
        port = host?.port ?? 22
        usesIdentity = host?.authentication.identityID != nil
        identityID = host?.authentication.identityID
        username = host?.authentication.manualUsername ?? ""
        authenticationMethods = host?.authentication.authenticationMethods.map { method in
            switch method {
            case .password(let secretID):
                IdentityDraftMethod(kind: .password(existingSecretID: secretID))
            case .accessKey(let credentialID):
                IdentityDraftMethod(kind: .accessKey(credentialID))
            }
        } ?? []
        group = host?.group ?? ""
        tagsText = host?.tags.joined(separator: ", ") ?? ""
        notes = host?.notes ?? ""
    }

    public var tags: [String] { tagsText.split(separator: ",").map(String.init) }
}

public enum AccessKeyDraftMode: String, CaseIterable, Sendable {
    case importExisting
    case generateSoftware
    case generateSecureEnclave
}

public struct AccessKeyDraft: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var credentialID: UUID?
    public var label = ""
    public var mode: AccessKeyDraftMode = .generateSoftware
    public var generation: SoftwareKeyGeneration = .ed25519
    public var privateKey = ""
    public var publicKey = ""
    public var comment = ""
    public var passphrase = ""
    public var passphraseConfirmation = ""
    public var savePassphrase = false
    public var acceptLegacyRSA1024 = false
    public var requiresUnlock = false
    public var originalAlgorithm: SSHKeyAlgorithm?
    public var suggestedLabelContext: String?
    public var suggestedOrdinal: Int?
    public init() {}

    public var automaticLabel: String {
        let ordinal = suggestedOrdinal ?? 1
        let context = suggestedLabelContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return context.isEmpty ? "Key #\(ordinal)" : "Key #\(ordinal) for “\(context)”"
    }
}

public enum AccessKeyImportPolicyError: LocalizedError, Equatable, Sendable {
    case legacyRSAConfirmationRequired

    public var errorDescription: String? {
        "RSA-1024 is obsolete and should be imported only for a known legacy server. Enable the compatibility confirmation to continue."
    }
}

public struct IdentityDraft: Identifiable, Equatable, Sendable {
    public var id: UUID?
    public var name: String
    public var username: String
    public var authenticationMethods: [IdentityDraftMethod]

    public init(identity: IdentityProfile? = nil) {
        id = identity?.id
        name = identity?.name ?? ""
        username = identity?.username ?? ""
        authenticationMethods = identity?.authenticationMethods.map { method in
            switch method {
            case .password(let secretID):
                IdentityDraftMethod(kind: .password(existingSecretID: secretID))
            case .accessKey(let credentialID):
                IdentityDraftMethod(kind: .accessKey(credentialID))
            }
        } ?? []
    }
}

public struct IdentityDraftMethod: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: IdentityDraftMethodKind
    public var password = ""

    public init(kind: IdentityDraftMethodKind) { self.kind = kind }
}

public enum IdentityDraftMethodKind: Equatable, Sendable {
    case password(existingSecretID: SecretID?)
    case accessKey(UUID)
}
