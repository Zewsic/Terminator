import Foundation
import Observation
import TerminatorCore

@MainActor
@Observable
public final class TerminatorAppModel {
    public var selection: AppSection = .hosts
    public internal(set) var hosts: [HostProfile] = []
    public internal(set) var tunnels: [TunnelProfile] = []
    public internal(set) var tunnelPhases: [UUID: SSHConnectionPhase] = [:]
    public internal(set) var credentials: [CredentialMetadata] = []
    public internal(set) var identities: [IdentityProfile] = []
    public internal(set) var history: [HistoryEntry] = []
    public internal(set) var containers: [ContainerSummary] = []
    public internal(set) var sessionLogs: [SessionLogMetadata] = []
    public internal(set) var terminalApplications: [TerminalApplication] = [.other]
    public internal(set) var openSSH = OpenSSHDiscoverySnapshot()
    public internal(set) var isScanningOpenSSH = false
    public internal(set) var importSources: [ExternalImportSource] = []
    public internal(set) var loadedImportSourceIDs: Set<String> = []
    public internal(set) var loadingImportSourceIDs: Set<String> = []
    public internal(set) var externalImportBundles: [String: ExternalImportBundle] = [:]
    public var openSSHResultMessage: String?
    public let connectionPrompts: ConnectionPromptCenter
    public var connectionHost: HostProfile?
    public internal(set) var backgroundConnectionHost: HostProfile?
    public internal(set) var connectionTerminal: TerminalApplication?
    public internal(set) var connectionPhase: SSHConnectionPhase = .disconnected
    public internal(set) var hostConnectionPhases: [UUID: SSHConnectionPhase] = [:]
    public internal(set) var isLoading = false
    public var presentedError: PresentedError?
    /// Lets platform shells refresh non-secret external search catalogs.
    public var onHostCatalogChanged: (@MainActor @Sendable ([HostProfile]) -> Void)?
    /// Direct edition: the window is suppressed for Spotlight/Raycast unless a prompt needs it.
    public var shouldRevealMainWindow = false

    public let capabilities: AppCapabilities

    let hostRepository: any HostRepository
    let credentialRepository: any CredentialRepository
    let identityRepository: any IdentityRepository
    let historyRepository: any HistoryRepository
    let secretStore: any SecretStore
    let accessKeyService: any AccessKeyService
    let userPresenceAuthorizer: any UserPresenceAuthorizer
    let dockerService: any DockerService
    let sessionLogRepository: (any SessionLogRepository)?
    let externalTerminalService: (any ExternalTerminalConnecting)?
    let sessionLogBaseURL: URL?
    let sessionLogExporter: (any SessionLogExporting)?
    let knownHostRepository: (any KnownHostRepository)?
    let openSSHService: (any OpenSSHIntegrationService)?
    let externalImportService: (any ExternalImportService)?
    let tunnelRepository: (any TunnelRepository)?
    let tunnelController: (any SSHTunnelControlling)?
    var connectionMonitors: [UUID: Task<Void, Never>] = [:]
    var tunnelMonitor: Task<Void, Never>?

    public init(
        capabilities: AppCapabilities,
        dependencies: TerminatorAppDependencies,
        connectionPrompts: ConnectionPromptCenter = ConnectionPromptCenter()
    ) {
        self.capabilities = capabilities
        self.hostRepository = dependencies.hostRepository
        self.credentialRepository = dependencies.credentialRepository
        self.identityRepository = dependencies.identityRepository
        self.historyRepository = dependencies.historyRepository
        self.secretStore = dependencies.secretStore
        self.accessKeyService = dependencies.accessKeyService
        self.userPresenceAuthorizer = dependencies.userPresenceAuthorizer
        self.dockerService = dependencies.dockerService
        self.sessionLogRepository = dependencies.sessionLogRepository
        self.externalTerminalService = dependencies.externalTerminalService
        self.connectionPrompts = connectionPrompts
        self.sessionLogBaseURL = dependencies.sessionLogBaseURL
        self.sessionLogExporter = dependencies.sessionLogExporter
        self.knownHostRepository = dependencies.knownHostRepository
        self.openSSHService = dependencies.openSSHService
        self.externalImportService = dependencies.externalImportService
        self.tunnelRepository = dependencies.tunnelRepository
        self.tunnelController = dependencies.tunnelController
        if dependencies.tunnelController != nil {
            tunnelMonitor = Task { [weak self] in
                guard let phases = await self?.tunnelController?.tunnelPhases() else { return }
                for await event in phases {
                    self?.tunnelPhases[event.id] = event.phase
                }
            }
        }
    }

    public convenience init(
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
        openSSHService: (any OpenSSHIntegrationService)? = nil,
        externalImportService: (any ExternalImportService)? = nil,
        tunnelRepository: (any TunnelRepository)? = nil,
        tunnelController: (any SSHTunnelControlling)? = nil
    ) {
        self.init(
            capabilities: capabilities,
            dependencies: TerminatorAppDependencies(
                hostRepository: hostRepository,
                credentialRepository: credentialRepository,
                identityRepository: identityRepository,
                historyRepository: historyRepository,
                secretStore: secretStore,
                accessKeyService: accessKeyService,
                userPresenceAuthorizer: userPresenceAuthorizer,
                dockerService: dockerService,
                sessionLogRepository: sessionLogRepository,
                externalTerminalService: externalTerminalService,
                sessionLogBaseURL: sessionLogBaseURL,
                sessionLogExporter: sessionLogExporter,
                knownHostRepository: knownHostRepository,
                openSSHService: openSSHService,
                externalImportService: externalImportService,
                tunnelRepository: tunnelRepository,
                tunnelController: tunnelController
            ),
            connectionPrompts: connectionPrompts
        )
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
            try await loadCatalog()
        } catch {
            if Self.isTransientStoreError(error) {
                try? await Task.sleep(for: .milliseconds(250))
                do {
                    try await loadCatalog()
                    return
                } catch {
                    present(error)
                    return
                }
            }
            present(error)
        }
    }

    private func loadCatalog() async throws {
        hosts = try await hostRepository.listHosts(includeDeleted: false)
        if let tunnelRepository { tunnels = try await tunnelRepository.listTunnels(includeDeleted: false) }
        onHostCatalogChanged?(hosts)
        credentials = try await credentialRepository.listCredentials(includeDeleted: true)
        identities = try await identityRepository.listIdentities(includeDeleted: true)
        history = try await historyRepository.listHistory(entity: nil)
        containers = try await dockerService.listContainers()
        if let sessionLogRepository { sessionLogs = try await sessionLogRepository.listSessionLogs() }
        if capabilities.externalTerminal, let externalTerminalService {
            terminalApplications = await externalTerminalService.installedApplications()
        }
        if capabilities.externalFileAccess { await refreshImportSources() }
    }

    private static func isTransientStoreError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "NSSQLiteErrorDomain" && [5, 6, 14].contains(ns.code) { return true }
        if ns.domain == NSCocoaErrorDomain && [4, 256, 257, 260].contains(ns.code) { return true }
        let message = ns.localizedDescription.lowercased()
        return message.contains("couldn't be opened")
            || message.contains("couldn’t be opened")
            || message.contains("busy")
            || message.contains("locked")
    }

    func present(_ error: any Error) {
        presentedError = PresentedError(error)
    }

    func present(id: String, message: String) {
        presentedError = PresentedError(id: id, message: message)
    }

    public func dismissPresentedError() {
        presentedError = nil
    }

}
