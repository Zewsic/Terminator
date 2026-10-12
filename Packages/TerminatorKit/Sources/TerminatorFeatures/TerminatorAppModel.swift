import Foundation
import Observation
import TerminatorCore

@MainActor
@Observable
public final class TerminatorAppModel {
    public var selection: AppSection = .hosts
    public internal(set) var hosts: [HostProfile] = []
    public internal(set) var archivedHosts: [HostProfile] = []
    public internal(set) var tunnels: [TunnelProfile] = []
    public internal(set) var archivedTunnels: [TunnelProfile] = []
    public internal(set) var snippets: [SnippetProfile] = []
    public internal(set) var archivedSnippets: [SnippetProfile] = []
    public internal(set) var tunnelPhases: [UUID: SSHConnectionPhase] = [:]
    public internal(set) var credentials: [CredentialMetadata] = []
    public internal(set) var identities: [IdentityProfile] = []
    public internal(set) var history: [HistoryEntry] = []
    public internal(set) var containers: [ContainerSummary] = []
    public internal(set) var dockerContainers: [DockerContainer] = []
    public internal(set) var dockerUpdating: [DockerEndpoint] = []
    public internal(set) var dockerInventoryReady = false
    public internal(set) var hostStatuses: [UUID: HostStatusSnapshot] = [:]
    var helperInstallations: [HelperInstallation] = []
    var helperOnline: Set<UUID> = []
    var helperStatuses: [UUID: HostStatusSnapshot] = [:]
    var helperContainers: [UUID: [DockerContainer]] = [:]
    var helperTokens: [UUID: String] = [:]
    var helperAdoptAfter: [UUID: Date] = [:]
    var helperUpdateAfter: [UUID: Date] = [:]
    var helperUpdating: Set<UUID> = []
    var serviceDockerContainers: [DockerContainer] = []
    var serviceDockerUpdating: [DockerEndpoint] = []
    var serviceDockerReady = false
    var serviceHostStatuses: [UUID: HostStatusSnapshot] = [:]
    var dockerProbed: Set<UUID> = []
    var dockerFailed: Set<UUID> = []
    var dockerProbing: Set<UUID> = []
    var helperPoller: Task<Void, Never>?
    public internal(set) var tunnelTraffic: [UUID: TunnelTrafficSnapshot] = [:]
    public var dockerOutput: DockerCommandOutput?
    public internal(set) var sessionLogs: [SessionLogMetadata] = []
    public internal(set) var terminalApplications: [TerminalApplication] = [.other]
    public internal(set) var openSSH = OpenSSHDiscoverySnapshot()
    public internal(set) var isScanningOpenSSH = false
    public internal(set) var importSources: [ExternalImportSource] = []
    public internal(set) var loadedImportSourceIDs: Set<String> = []
    public internal(set) var loadingImportSourceIDs: Set<String> = []
    public internal(set) var externalImportBundles: [String: ExternalImportBundle] = [:]
    public var openSSHResultMessage: String?
    /// Suppresses one-off import alerts while a catalog picker imports several records.
    public var suppressesImportAnnouncements = false
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
    let snippetRepository: (any SnippetRepository)?
    let activityLog: (any ActivityLogRecording)?
    var connectionMonitors: [UUID: Task<Void, Never>] = [:]
    var tunnelMonitor: Task<Void, Never>?
    var dockerMonitor: Task<Void, Never>?
    var statusMonitor: Task<Void, Never>?
    var trafficMonitor: Task<Void, Never>?

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
        self.snippetRepository = dependencies.snippetRepository
        self.activityLog = dependencies.activityLog
        if dependencies.tunnelController != nil {
            tunnelMonitor = Task { [weak self] in
                guard let phases = await self?.tunnelController?.tunnelPhases() else { return }
                for await event in phases {
                    self?.tunnelPhases[event.id] = event.phase
                }
            }
            dockerMonitor = Task { [weak self] in
                guard let inventory = await self?.tunnelController?.dockerInventory() else { return }
                for await snapshot in inventory {
                    self?.noteDocker(snapshot)
                }
            }
            statusMonitor = Task { [weak self] in
                guard let statuses = await self?.tunnelController?.hostStatuses() else { return }
                for await snapshot in statuses {
                    self?.noteServiceStatus(snapshot)
                }
            }
            trafficMonitor = Task { [weak self] in
                guard let traffic = await self?.tunnelController?.tunnelTraffic() else { return }
                for await snapshot in traffic {
                    self?.tunnelTraffic[snapshot.id] = snapshot
                }
            }
        }
        if dependencies.externalTerminalService != nil || dependencies.tunnelController != nil {
            startHelperPolling()
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
        tunnelController: (any SSHTunnelControlling)? = nil,
        snippetRepository: (any SnippetRepository)? = nil,
        activityLog: (any ActivityLogRecording)? = nil
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
                tunnelController: tunnelController,
                snippetRepository: snippetRepository,
                activityLog: activityLog
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
        let allHosts = try await hostRepository.listHosts(includeDeleted: true)
        hosts = allHosts.filter { !$0.isDeleted }
        archivedHosts = allHosts.filter(\.isDeleted)
        if let tunnelRepository {
            let allTunnels = try await tunnelRepository.listTunnels(includeDeleted: true)
            tunnels = allTunnels.filter { !$0.isDeleted }
            archivedTunnels = allTunnels.filter(\.isDeleted)
        }
        if let snippetRepository {
            let allSnippets = try await snippetRepository.listSnippets(includeDeleted: true)
            snippets = allSnippets.filter { !$0.isDeleted }
            archivedSnippets = allSnippets.filter(\.isDeleted)
        }
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
        trackHostConnections()
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

    public func runDocker(_ container: DockerContainer, action: DockerControlAction) async {
        if await runDockerThroughHelper(container, action: action) { return }
        guard let tunnelController else { return }
        do {
            let text = try await tunnelController.controlDocker(
                endpoint: container.endpoint,
                containerID: container.id,
                action: action
            )
            if action == .logs || action == .stats {
                dockerOutput = DockerCommandOutput(
                    title: "\(container.name) · \(action.rawValue)",
                    text: text.isEmpty ? " " : text
                )
            }
        } catch {
            present(error)
        }
    }

    public func runDocker(_ containers: [DockerContainer], action: DockerControlAction, title: String) async {
        let targets = containers.filter { DockerGroup.applies(action, to: $0) }
        guard !targets.isEmpty else { return }
        if action == .logs {
            var sections: [String] = []
            for container in containers {
                let text = await dockerLogText(container)
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append("\(container.name)\n\(body.isEmpty ? "—" : body)")
            }
            dockerOutput = DockerCommandOutput(
                title: "\(title) · \(action.rawValue)",
                text: sections.joined(separator: "\n\n")
            )
            return
        }
        for container in targets {
            await runDocker(container, action: action)
        }
    }

    public func openContainerShell(_ container: DockerContainer) async {
        guard let tunnelController else { return }
        do {
            try await tunnelController.openContainerShell(endpoint: container.endpoint, containerID: container.id)
        } catch {
            present(error)
        }
    }
}

public struct DockerCommandOutput: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var text: String

    public init(id: UUID = UUID(), title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}
