import SwiftData
import SwiftUI
#if !APP_STORE
import AppKit
#endif
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
    @NSApplicationDelegateAdaptor(TerminatorAppDelegate.self) private var appDelegate
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
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appending(path: "Terminator", directoryHint: .isDirectory)
            let logURL = support.appending(path: "SessionLogs", directoryHint: .isDirectory)
            let connectionPrompts = ConnectionPromptCenter()
            let spotlightIndexer = SpotlightHostIndexer()
            let connectionClient = ConnectionServiceClient()
            let terminalService = MacExternalTerminalService(client: connectionClient)
            let logExporter = MacSessionLogExporter(secretStore: secretStore, baseURL: logURL)
            let openSSHService = MacOpenSSHIntegrationService()
            let externalImportService = MacTermiusImportService()
            let appModel = TerminatorAppModel(
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
                openSSHService: openSSHService,
                externalImportService: externalImportService
            )
            connectionPrompts.onPrompt = {
                appModel.revealBackgroundConnectionIfNeeded()
                TerminatorMainWindow.reveal()
            }
            appModel.onHostCatalogChanged = { hosts in
                Task {
                    if AccessPreferencesStore.load().cliEnabled {
                        await spotlightIndexer.index(hosts)
                        try? RaycastServerCatalog().write(hosts: hosts, applicationSupportURL: support)
                    } else {
                        await spotlightIndexer.clear()
                    }
                }
            }
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(TerminatorDistributedNotification.accessChanged),
                object: nil,
                queue: .main
            ) { _ in
                appModel.onHostCatalogChanged?(appModel.hosts)
            }
            _appModel = State(initialValue: appModel)
            TerminatorMainWindow.model = appModel
            TerminatorGUIActions.revealMain = { TerminatorMainWindow.reveal() }
            TerminatorGUIActions.connectHost = { hostID in
                Task { await appModel.connectInBackground(hostID: hostID, with: .terminal) }
            }
            Task { await appModel.load() }
            Task {
                await connectionClient.setPromptHandler { envelope in
                    await appModel.answerServicePrompt(envelope)
                }
                await ConnectionServiceSupport.ensureRunning()
            }
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
            fatalError("Unable to initialize Terminator's local store: \(error)")
        }
    }

    var body: some Scene {
        #if APP_STORE
        WindowGroup {
            RootView()
                .environment(appModel)
                .task { await appModel.load() }
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 760)
        #endif

        Settings {
            SettingsView(capabilities: appModel.capabilities)
        }
        #if !APP_STORE
        .defaultLaunchBehavior(.suppressed)
        #endif
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
