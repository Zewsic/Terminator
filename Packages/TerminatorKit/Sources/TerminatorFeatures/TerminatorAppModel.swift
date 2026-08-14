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
    public private(set) var sessionLogs: [SessionLogMetadata] = []
    public private(set) var terminalApplications: [TerminalApplication] = [.other]
    public private(set) var openSSH = OpenSSHDiscoverySnapshot()
    public private(set) var isScanningOpenSSH = false
    public var openSSHResultMessage: String?
    public let connectionPrompts: ConnectionPromptCenter
    public var connectionHost: HostProfile?
    public private(set) var connectionTerminal: TerminalApplication?
    public private(set) var connectionPhase: SSHConnectionPhase = .disconnected
    public private(set) var hostConnectionPhases: [UUID: SSHConnectionPhase] = [:]
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
    private let sessionLogRepository: (any SessionLogRepository)?
    private let externalTerminalService: (any ExternalTerminalConnecting)?
    private let sessionLogBaseURL: URL?
    private let sessionLogExporter: (any SessionLogExporting)?
    private let knownHostRepository: (any KnownHostRepository)?
    private let openSSHService: (any OpenSSHIntegrationService)?
    private var connectionMonitors: [UUID: Task<Void, Never>] = [:]

    public init(
        capabilities: AppCapabilities,
        hostRepository: any HostRepository,
        credentialRepository: any CredentialRepository,
        identityRepository: any IdentityRepository,
        historyRepository: any HistoryRepository,
        secretStore: any SecretStore,
        accessKeyService: any AccessKeyService,
        userPresenceAuthorizer: any UserPresenceAuthorizer,
        dockerService: any DockerService,
        sessionLogRepository: (any SessionLogRepository)? = nil,
        externalTerminalService: (any ExternalTerminalConnecting)? = nil,
        connectionPrompts: ConnectionPromptCenter = ConnectionPromptCenter(),
        sessionLogBaseURL: URL? = nil,
        sessionLogExporter: (any SessionLogExporting)? = nil,
        knownHostRepository: (any KnownHostRepository)? = nil,
        openSSHService: (any OpenSSHIntegrationService)? = nil
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
        self.sessionLogRepository = sessionLogRepository
        self.externalTerminalService = externalTerminalService
        self.connectionPrompts = connectionPrompts
        self.sessionLogBaseURL = sessionLogBaseURL
        self.sessionLogExporter = sessionLogExporter
        self.knownHostRepository = knownHostRepository
        self.openSSHService = openSSHService
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
            if let sessionLogRepository { sessionLogs = try await sessionLogRepository.listSessionLogs() }
            if capabilities.externalTerminal, let externalTerminalService {
                terminalApplications = await externalTerminalService.installedApplications()
            }
            if capabilities.externalFileAccess, openSSHService != nil { await refreshOpenSSH() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshOpenSSH() async {
        guard capabilities.externalFileAccess, let openSSHService else { return }
        isScanningOpenSSH = true
        defer { isScanningOpenSSH = false }
        do {
            let endpoints = hosts.map { $0.port == 22 ? $0.hostname : "[\($0.hostname)]:\($0.port)" }
            var snapshot = try await openSSHService.scan(knownEndpoints: endpoints)
            for index in snapshot.accessKeys.indices
            where snapshot.accessKeys[index].fingerprint == nil && !snapshot.accessKeys[index].isEncrypted {
                if let prepared = try? await accessKeyService.importSoftwareKey(.init(
                    privateKey: snapshot.accessKeys[index].privateKey,
                    suppliedPublicKey: snapshot.accessKeys[index].publicKey
                )) {
                    snapshot.accessKeys[index].fingerprint = prepared.fingerprint
                    snapshot.accessKeys[index].publicKey = prepared.publicKey
                }
            }
            for index in snapshot.hosts.indices {
                snapshot.hosts[index].status = matchingHost(for: snapshot.hosts[index]) == nil ? .available : .existing
            }
            for index in snapshot.accessKeys.indices {
                if let fingerprint = snapshot.accessKeys[index].fingerprint,
                   credentials.contains(where: { $0.accessKey?.fingerprint == fingerprint && !$0.isDeleted }) {
                    snapshot.accessKeys[index].status = .existing
                }
            }
            if let knownHostRepository {
                for index in snapshot.knownHosts.indices {
                    let item = snapshot.knownHosts[index]
                    let stored = try await knownHostRepository.knownHost(endpoint: item.endpoint, algorithm: item.algorithm)
                    if stored == nil {
                        try await knownHostRepository.saveKnownHost(.init(
                            endpoint: item.endpoint,
                            algorithm: item.algorithm,
                            publicKey: item.publicKey,
                            fingerprint: item.fingerprint
                        ))
                        snapshot.knownHosts[index].status = .existing
                    } else {
                        snapshot.knownHosts[index].status = stored?.publicKey == item.publicKey ? .existing : .changed
                    }
                }
            }
            openSSH = snapshot
        } catch { errorMessage = error.localizedDescription }
    }

    public func matchingHost(for discovered: DiscoveredSSHHost) -> HostProfile? {
        hosts.first { host in
            host.hostname.normalizedSSHEndpoint == discovered.hostname.normalizedSSHEndpoint
                && host.port == discovered.port
                && resolvedUsername(for: host).caseInsensitiveCompare(discovered.username) == .orderedSame
        }
    }

    public func discoveredKey(at url: URL) -> DiscoveredAccessKey? {
        openSSH.accessKeys.first { $0.privateKeyURL.standardizedFileURL == url.standardizedFileURL }
    }

    public func draft(for discovered: DiscoveredAccessKey) -> AccessKeyDraft {
        var draft = AccessKeyDraft()
        draft.label = discovered.label
        draft.mode = .importExisting
        draft.privateKey = discovered.privateKey
        draft.publicKey = discovered.publicKey
        return draft
    }

    public func importKnownHost(_ discovered: DiscoveredKnownHost, replaceChanged: Bool = false) async -> Bool {
        guard let knownHostRepository else { return false }
        do {
            if let stored = try await knownHostRepository.knownHost(
                endpoint: discovered.endpoint, algorithm: discovered.algorithm
            ), stored.publicKey != discovered.publicKey, !replaceChanged {
                errorMessage = "The stored host key differs. Confirm the replacement explicitly."
                return false
            }
            let previous = try await knownHostRepository.knownHost(
                endpoint: discovered.endpoint, algorithm: discovered.algorithm
            )
            try await knownHostRepository.saveKnownHost(.init(
                id: previous?.id ?? UUID(), endpoint: discovered.endpoint,
                algorithm: discovered.algorithm, publicKey: discovered.publicKey,
                fingerprint: discovered.fingerprint, createdAt: previous?.createdAt ?? .now
            ))
            openSSHResultMessage = previous == nil ? "Trusted host imported." : "Trusted host updated."
            await refreshOpenSSH()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    public func importHost(_ discovered: DiscoveredSSHHost, credentialIDs: [UUID]) async -> Bool {
        let existing = matchingHost(for: discovered)
        var methods = existing?.authentication.authenticationMethods ?? []
        if let identityID = existing?.authentication.identityID,
           let identity = identities.first(where: { $0.id == identityID }) {
            methods = identity.authenticationMethods
        }
        for id in credentialIDs where !methods.contains(.accessKey(credentialID: id)) {
            methods.append(.accessKey(credentialID: id))
        }
        var draft = HostDraft()
        draft.id = existing?.id
        draft.displayName = discovered.alias
        draft.hostname = discovered.hostname
        draft.port = discovered.port
        draft.usesIdentity = false
        draft.username = discovered.username
        draft.authenticationMethods = methods.map { method in
            switch method {
            case .password(let secretID):
                IdentityDraftMethod(kind: .password(existingSecretID: secretID))
            case .accessKey(let credentialID):
                IdentityDraftMethod(kind: .accessKey(credentialID))
            }
        }
        draft.group = existing?.group ?? ""
        draft.tagsText = existing?.tags.joined(separator: ", ") ?? ""
        draft.notes = existing?.notes ?? ""
        let saved = await saveHost(draft)
        if saved {
            openSSHResultMessage = existing == nil ? "Host imported." : "Host updated from OpenSSH."
            await refreshOpenSSH()
        }
        return saved
    }

    public func hostExportRequest(
        for host: HostProfile, configURL: URL, keyURLs: [URL], replaceExisting: Bool
    ) -> OpenSSHHostExportRequest {
        .init(
            alias: host.displayName.replacingOccurrences(of: " ", with: "-"),
            hostname: host.hostname, port: host.port, username: resolvedUsername(for: host),
            identityFiles: keyURLs, configURL: configURL, replaceExisting: replaceExisting
        )
    }

    public func previewOpenSSHExport(_ request: OpenSSHHostExportRequest) async -> String {
        await openSSHService?.hostBlock(for: request) ?? ""
    }

    public func compareOpenSSHExport(_ request: OpenSSHHostExportRequest) async -> OpenSSHHostExportComparison? {
        do { return try await openSSHService?.comparison(for: request) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    public func exportHostToOpenSSH(
        _ request: OpenSSHHostExportRequest,
        keyExports: [(credentialID: UUID, privateURL: URL?, publicURL: URL?)],
        replaceFiles: Bool,
        passphrases: [UUID: String] = [:]
    ) async -> Bool {
        guard let openSSHService else { return false }
        do {
            for item in keyExports {
                guard let credential = credentials.first(where: { $0.id == item.credentialID }),
                      let key = credential.accessKey else { continue }
                if let publicURL = item.publicURL, let publicData = (key.publicKey + "\n").data(using: .utf8) {
                    try await openSSHService.writeKey(publicData, to: publicURL, privateKey: false, replaceExisting: replaceFiles)
                }
                if let privateURL = item.privateURL {
                    guard let data = await exportPrivateKey(
                        id: credential.id, passphrase: passphrases[credential.id] ?? ""
                    ) else { return false }
                    try await openSSHService.writeKey(data, to: privateURL, privateKey: true, replaceExisting: replaceFiles)
                }
            }
            try await openSSHService.exportHost(request)
            await refreshOpenSSH()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    public func resolvedUsername(for host: HostProfile) -> String {
        if case .manual(let username, _) = host.authentication { return username }
        guard let id = host.authentication.identityID else { return "" }
        return identities.first { $0.id == id }?.username ?? ""
    }

    public func connect(_ host: HostProfile, with terminal: TerminalApplication) async {
        guard capabilities.externalTerminal, let externalTerminalService else { return }
        connectionHost = host
        connectionTerminal = terminal
        connectionPhase = .resolving
        hostConnectionPhases[host.id] = .resolving
        beginMonitoringConnection(hostID: host.id, service: externalTerminalService)
        do {
            try await externalTerminalService.connect(host: host, terminal: terminal)
            connectionPhase = .connected
            hostConnectionPhases[host.id] = .connected
        } catch is CancellationError {
            connectionPhase = .disconnected
            hostConnectionPhases[host.id] = .disconnected
            stopMonitoringConnection(hostID: host.id)
        } catch {
            connectionPhase = .failed(message: error.localizedDescription)
            hostConnectionPhases[host.id] = .failed(message: error.localizedDescription)
            stopMonitoringConnection(hostID: host.id)
        }
    }

    public func connectionPhase(for hostID: UUID) -> SSHConnectionPhase {
        hostConnectionPhases[hostID] ?? .disconnected
    }

    public func disconnect(_ host: HostProfile) async {
        guard let externalTerminalService else { return }
        connectionPrompts.cancel()
        await externalTerminalService.disconnect(hostID: host.id)
        stopMonitoringConnection(hostID: host.id)
        hostConnectionPhases[host.id] = .disconnected
        if connectionHost?.id == host.id {
            connectionHost = nil
            connectionTerminal = nil
            connectionPhase = .disconnected
        }
    }

    public func retryConnection() async {
        guard let host = connectionHost, let terminal = connectionTerminal else { return }
        await connect(host, with: terminal)
    }

    public func makeConnectionCommand() async -> String? {
        guard let host = connectionHost, let externalTerminalService else { return nil }
        do {
            return try await externalTerminalService.makeConnectionCommand(host: host)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func cancelConnectionPresentation() async {
        guard let host = connectionHost else {
            dismissConnection()
            return
        }
        if case .connected = connectionPhase {
            dismissConnection()
            return
        }
        connectionPrompts.cancel()
        if let externalTerminalService {
            await externalTerminalService.disconnect(hostID: host.id)
        }
        stopMonitoringConnection(hostID: host.id)
        hostConnectionPhases[host.id] = .disconnected
        connectionHost = nil
        connectionTerminal = nil
        connectionPhase = .disconnected
    }

    private func beginMonitoringConnection(
        hostID: UUID,
        service: any ExternalTerminalConnecting
    ) {
        connectionMonitors[hostID]?.cancel()
        connectionMonitors[hostID] = Task { [weak self] in
            while !Task.isCancelled {
                let phase = await service.state(for: hostID)
                guard !Task.isCancelled, let self else { return }
                self.hostConnectionPhases[hostID] = phase
                if self.connectionHost?.id == hostID { self.connectionPhase = phase }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopMonitoringConnection(hostID: UUID) {
        connectionMonitors[hostID]?.cancel()
        connectionMonitors[hostID] = nil
    }

    public func dismissConnection() {
        connectionPrompts.cancel()
        connectionHost = nil
        connectionTerminal = nil
        connectionPhase = .disconnected
    }

    public func setLogPinned(_ id: UUID, pinned: Bool) async {
        guard let sessionLogRepository, var log = sessionLogs.first(where: { $0.id == id }) else { return }
        do { log.isPinned = pinned; try await sessionLogRepository.saveSessionLog(log); await load() }
        catch { errorMessage = error.localizedDescription }
    }

    public func deleteLog(_ log: SessionLogMetadata) async {
        guard let sessionLogRepository, log.state != .active else { return }
        do {
            if let sessionLogBaseURL {
                try? FileManager.default.removeItem(at: sessionLogBaseURL.appending(path: log.relativePath))
            }
            try await sessionLogRepository.deleteSessionLog(id: log.id)
            try? await secretStore.purge(id: log.encryptionKeyID)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func exportLog(_ log: SessionLogMetadata) async {
        guard let sessionLogExporter else { return }
        do { _ = try await sessionLogExporter.export(log) }
        catch { errorMessage = error.localizedDescription }
    }

    public func saveHost(_ draft: HostDraft) async -> Bool {
        var newPasswordIDs: [SecretID] = []
        var replacedPasswordIDs: [SecretID] = []
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
                        let value = method.password
                        let shouldReplace = method.passwordChanged || (existingSecretID == nil && !value.isEmpty)
                        if shouldReplace, !value.isEmpty {
                            let secretID = SecretID()
                            try await secretStore.store(Data(value.utf8), for: secretID)
                            newPasswordIDs.append(secretID)
                            methods.append(.password(secretID: secretID))
                            if let existingSecretID { replacedPasswordIDs.append(existingSecretID) }
                        } else if shouldReplace, let existingSecretID {
                            replacedPasswordIDs.append(existingSecretID)
                        } else if let existingSecretID {
                            methods.append(.password(secretID: existingSecretID))
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
                for id in newPasswordIDs { try? await secretStore.purge(id: id) }
                throw error
            }
            for id in replacedPasswordIDs { try? await secretStore.purge(id: id) }
            await load()
            return true
        } catch {
            for id in newPasswordIDs { try? await secretStore.purge(id: id) }
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func loadHostPassword(into draft: HostDraft) async -> HostDraft {
        var copy = draft
        guard let index = copy.authenticationMethods.firstIndex(where: { method in
            if case .password(let id) = method.kind { return id != nil }
            return false
        }), case .password(let secretID?) = copy.authenticationMethods[index].kind else {
            return copy
        }
        do {
            let data = try await secretStore.read(id: secretID)
            guard let value = String(data: data, encoding: .utf8) else {
                throw CredentialValidationError.missingSecret
            }
            copy.authenticationMethods[index].password = value
            copy.authenticationMethods[index].passwordChanged = false
        } catch {
            errorMessage = error.localizedDescription
        }
        return copy
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

            if draft.mode == .importExisting,
               let existing = activeCredentials.first(where: { $0.accessKey?.fingerprint == prepared.fingerprint }) {
                openSSHResultMessage = FeatureL10n.text("openSSH.credential.reused", existing.label)
                return existing.id
            }

            if prepared.compatibility == .legacyRSA1024, !draft.acceptLegacyRSA1024 {
                throw AccessKeyImportPolicyError.legacyRSAConfirmationRequired
            }

            let privateID = SecretID()
            var storedIDs = [privateID]
            var privateMaterial = prepared.privateMaterial
            var protection: PassphraseProtection = prepared.isPassphraseProtected ? .promptEveryConnection : .none
            if prepared.isPassphraseProtected, !draft.passphrase.isEmpty, !draft.savePassphrase {
                privateMaterial = try await accessKeyService.exportSoftwareKey(
                    privateMaterial: prepared.privateMaterial,
                    passphrase: draft.passphrase
                )
                protection = .none
            }
            try await secretStore.store(privateMaterial, for: privateID)
            if prepared.isPassphraseProtected, draft.savePassphrase, !draft.passphrase.isEmpty,
               let data = draft.passphrase.data(using: .utf8) {
                let passphraseID = SecretID()
                do { try await secretStore.store(data, for: passphraseID, access: .userPresence) }
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
            try await userPresenceAuthorizer.authorize(reason: FeatureL10n.text("authentication.revealPrivateKey", credential.label))
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
        if draft.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !draft.passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = "Unlock Private Key first."
                return false
            }
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
            var privateMaterial = prepared.privateMaterial
            var protection: PassphraseProtection = prepared.isPassphraseProtected ? .promptEveryConnection : .none
            if prepared.isPassphraseProtected, !draft.passphrase.isEmpty, !draft.savePassphrase {
                privateMaterial = try await accessKeyService.exportSoftwareKey(
                    privateMaterial: prepared.privateMaterial,
                    passphrase: draft.passphrase
                )
                protection = .none
            }
            var newItems: [(SecretID, Data, SecretAccessPolicy)] = [(privateID, privateMaterial, .deviceOnly)]
            if prepared.isPassphraseProtected, draft.savePassphrase,
               let data = draft.passphrase.data(using: .utf8), !data.isEmpty {
                let passphraseID = SecretID()
                newItems.append((passphraseID, data, .userPresence))
                protection = .saved(secretID: passphraseID)
            }

            var stored: [SecretID] = []
            do {
                for (secretID, data, access) in newItems {
                    try await secretStore.store(data, for: secretID, access: access)
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
            try await userPresenceAuthorizer.authorize(reason: FeatureL10n.text("authentication.exportPrivateKey", credential.label))
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
        guard let context, !context.isEmpty else { return FeatureL10n.text("key.automaticLabel", ordinal) }
        return FeatureL10n.text("key.automaticLabel.context", ordinal, context)
    }

    public func saveIdentity(_ draft: IdentityDraft) async -> Bool {
        var newPasswordIDs: [SecretID] = []
        var replacedPasswordIDs: [SecretID] = []
        do {
            let existing = draft.id.flatMap { id in identities.first(where: { $0.id == id }) }
            let now = Date.now
            var methods: [AuthenticationMethod] = []
            for method in draft.authenticationMethods {
                switch method.kind {
                case .accessKey(let credentialID):
                    methods.append(.accessKey(credentialID: credentialID))
                case .password(let existingSecretID):
                    let value = method.password
                    let shouldReplace = method.passwordChanged || (existingSecretID == nil && !value.isEmpty)
                    if shouldReplace, !value.isEmpty {
                        let secretID = SecretID()
                        guard let data = value.data(using: .utf8) else {
                            throw CredentialValidationError.missingSecret
                        }
                        try await secretStore.store(data, for: secretID)
                        newPasswordIDs.append(secretID)
                        methods.append(.password(secretID: secretID))
                        if let existingSecretID { replacedPasswordIDs.append(existingSecretID) }
                    } else if shouldReplace, let existingSecretID {
                        replacedPasswordIDs.append(existingSecretID)
                    } else if let existingSecretID {
                        methods.append(.password(secretID: existingSecretID))
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
                for id in newPasswordIDs { try? await secretStore.purge(id: id) }
                throw error
            }
            for id in replacedPasswordIDs { try? await secretStore.purge(id: id) }
            await load()
            return true
        } catch {
            for id in newPasswordIDs { try? await secretStore.purge(id: id) }
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func loadIdentityPassword(into draft: IdentityDraft) async -> IdentityDraft {
        var copy = draft
        guard let index = copy.authenticationMethods.firstIndex(where: { method in
            if case .password(let id) = method.kind { return id != nil }
            return false
        }), case .password(let secretID?) = copy.authenticationMethods[index].kind else {
            return copy
        }
        do {
            let data = try await secretStore.read(id: secretID)
            guard let value = String(data: data, encoding: .utf8) else {
                throw CredentialValidationError.missingSecret
            }
            copy.authenticationMethods[index].password = value
            copy.authenticationMethods[index].passwordChanged = false
        } catch {
            errorMessage = error.localizedDescription
        }
        return copy
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
        let methods: [IdentityDraftMethod] = host?.authentication.authenticationMethods.map { method in
            switch method {
            case .password(let secretID):
                return IdentityDraftMethod(kind: .password(existingSecretID: secretID))
            case .accessKey(let credentialID):
                return IdentityDraftMethod(kind: .accessKey(credentialID))
            }
        } ?? []
        let password = methods.first { method in
            if case .password = method.kind { return true }
            return false
        } ?? IdentityDraftMethod(kind: .password(existingSecretID: nil))
        authenticationMethods = [password] + methods.filter { method in
            if case .accessKey = method.kind { return true }
            return false
        }
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
        return context.isEmpty
            ? FeatureL10n.text("key.automaticLabel", ordinal)
            : FeatureL10n.text("key.automaticLabel.context", ordinal, context)
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
        let methods: [IdentityDraftMethod] = identity?.authenticationMethods.map { method -> IdentityDraftMethod in
            switch method {
            case .password(let secretID):
                IdentityDraftMethod(kind: .password(existingSecretID: secretID))
            case .accessKey(let credentialID):
                IdentityDraftMethod(kind: .accessKey(credentialID))
            }
        } ?? []
        let password = methods.first { method in
            if case .password = method.kind { return true }
            return false
        } ?? IdentityDraftMethod(kind: .password(existingSecretID: nil))
        authenticationMethods = [password] + methods.filter { method in
            if case .accessKey = method.kind { return true }
            return false
        }
    }
}

public struct IdentityDraftMethod: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: IdentityDraftMethodKind
    public var password = ""
    public var passwordChanged = false

    public init(kind: IdentityDraftMethodKind) { self.kind = kind }
}

public enum IdentityDraftMethodKind: Equatable, Sendable {
    case password(existingSecretID: SecretID?)
    case accessKey(UUID)
}

private extension String {
    var normalizedSSHEndpoint: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
