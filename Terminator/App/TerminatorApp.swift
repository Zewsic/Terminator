import SwiftData
import SwiftUI
import TerminatorCore
import TerminatorFeatures
import TerminatorPersistence
import TerminatorSecurity
#if !APP_STORE
import TerminatorSSH
#endif

@main
@MainActor
struct TerminatorApp: App {
    private let modelContainer: ModelContainer
    @State private var appModel: TerminatorAppModel

    init() {
        do {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            let container = try TerminatorSchema.makeContainer(inMemory: isUITesting)
            let store = TerminatorStore(modelContainer: container)
            let secretStore = KeychainSecretStore(service: "pro.zewsic.terminator.secrets")
            let accessKeyService = AppleAccessKeyService()
            modelContainer = container
            #if APP_STORE
            _appModel = State(
                initialValue: TerminatorAppModel(
                    capabilities: .current,
                    hostRepository: store,
                    credentialRepository: store,
                    identityRepository: store,
                    historyRepository: store,
                    secretStore: secretStore,
                    accessKeyService: accessKeyService,
                    userPresenceAuthorizer: LocalAuthenticationAuthorizer(),
                    dockerService: DemoDockerService(),
                    sessionLogRepository: store
                )
            )
            #else
            let authenticationResolver = AuthenticationResolver(
                credentialRepository: store, identityRepository: store, secretStore: secretStore
            )
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appending(path: "Terminator", directoryHint: .isDirectory)
            let logURL = support.appending(path: "SessionLogs", directoryHint: .isDirectory)
            let coordinator = NIOSSHConnectionCoordinator(
                authenticationResolver: authenticationResolver,
                accessKeyService: accessKeyService,
                knownHosts: store,
                logRepository: store,
                secretStore: secretStore,
                logBaseURL: logURL
            )
            let broker = TerminalAttachBroker(
                coordinator: coordinator,
                directoryURL: support.appending(path: "Attach", directoryHint: .isDirectory)
            )
            let connectionPrompts = ConnectionPromptCenter()
            let terminalService = MacExternalTerminalService(
                coordinator: coordinator,
                broker: broker,
                prompting: MacConnectionPrompter(center: connectionPrompts)
            )
            let logExporter = MacSessionLogExporter(secretStore: secretStore, baseURL: logURL)
            let openSSHService = MacOpenSSHIntegrationService()
            _appModel = State(initialValue: TerminatorAppModel(
                capabilities: .current,
                hostRepository: store,
                credentialRepository: store,
                identityRepository: store,
                historyRepository: store,
                secretStore: secretStore,
                accessKeyService: accessKeyService,
                userPresenceAuthorizer: LocalAuthenticationAuthorizer(),
                dockerService: DemoDockerService(),
                sessionLogRepository: store,
                externalTerminalService: terminalService,
                connectionPrompts: connectionPrompts,
                sessionLogBaseURL: logURL,
                sessionLogExporter: logExporter,
                knownHostRepository: store,
                openSSHService: openSSHService
            ))
            Task.detached {
                while !Task.isCancelled {
                    let days = max(1, UserDefaults.standard.integer(forKey: "sessionLogRetentionDays"))
                    let effectiveDays = UserDefaults.standard.object(forKey: "sessionLogRetentionDays") == nil ? 90 : days
                    await SessionLogWriter.purgeExpired(
                        olderThan: .now.addingTimeInterval(-Double(effectiveDays) * 86_400),
                        repository: store, secretStore: secretStore, baseURL: logURL
                    )
                    try? await Task.sleep(for: .seconds(86_400))
                }
            }
            #endif
        } catch {
            fatalError("Unable to initialize Terminator's local store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .task { await appModel.load() }
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView(capabilities: appModel.capabilities)
        }
    }
}

private extension AppCapabilities {
    static var current: AppCapabilities {
        #if APP_STORE
        .appStore
        #else
        .direct
        #endif
    }
}
