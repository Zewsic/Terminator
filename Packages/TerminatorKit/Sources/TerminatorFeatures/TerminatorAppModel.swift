import Foundation
import Observation
import TerminatorCore

@MainActor
@Observable
public final class TerminatorAppModel {
    public var selection: AppSection = .overview
    public internal(set) var hosts: [HostProfile] = []
    public internal(set) var credentials: [CredentialMetadata] = []
    public internal(set) var identities: [IdentityProfile] = []
    public internal(set) var history: [HistoryEntry] = []
    public internal(set) var containers: [ContainerSummary] = []
    public internal(set) var sessionLogs: [SessionLogMetadata] = []
    public internal(set) var terminalApplications: [TerminalApplication] = [.other]
    public internal(set) var openSSH = OpenSSHDiscoverySnapshot()
    public internal(set) var isScanningOpenSSH = false
    public var openSSHResultMessage: String?
    public let connectionPrompts: ConnectionPromptCenter
    public var connectionHost: HostProfile?
    public internal(set) var connectionTerminal: TerminalApplication?
    public internal(set) var connectionPhase: SSHConnectionPhase = .disconnected
    public internal(set) var hostConnectionPhases: [UUID: SSHConnectionPhase] = [:]
    public internal(set) var isLoading = false
    public var presentedError: PresentedError?

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
    var connectionMonitors: [UUID: Task<Void, Never>] = [:]

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
        openSSHService: (any OpenSSHIntegrationService)? = nil
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
                openSSHService: openSSHService
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
            present(error)
        }
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
