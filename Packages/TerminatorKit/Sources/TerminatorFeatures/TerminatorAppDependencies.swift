import Foundation
import TerminatorCore

/// Services used by the feature layer. Keeping them in one value makes the
/// composition boundary explicit without exposing concrete platform types.
public struct TerminatorAppDependencies: Sendable {
    public let hostRepository: any HostRepository
    public let credentialRepository: any CredentialRepository
    public let identityRepository: any IdentityRepository
    public let historyRepository: any HistoryRepository
    public let secretStore: any SecretStore
    public let accessKeyService: any AccessKeyService
    public let userPresenceAuthorizer: any UserPresenceAuthorizer
    public let dockerService: any DockerService
    public let sessionLogRepository: (any SessionLogRepository)?
    public let externalTerminalService: (any ExternalTerminalConnecting)?
    public let sessionLogBaseURL: URL?
    public let sessionLogExporter: (any SessionLogExporting)?
    public let knownHostRepository: (any KnownHostRepository)?
    public let openSSHService: (any OpenSSHIntegrationService)?
    public let externalImportService: (any ExternalImportService)?

    public init(
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
        sessionLogBaseURL: URL? = nil,
        sessionLogExporter: (any SessionLogExporting)? = nil,
        knownHostRepository: (any KnownHostRepository)? = nil,
        openSSHService: (any OpenSSHIntegrationService)? = nil,
        externalImportService: (any ExternalImportService)? = nil
    ) {
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
        self.sessionLogBaseURL = sessionLogBaseURL
        self.sessionLogExporter = sessionLogExporter
        self.knownHostRepository = knownHostRepository
        self.openSSHService = openSSHService
        self.externalImportService = externalImportService
    }
}
