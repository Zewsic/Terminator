import SwiftData
import SwiftUI
import TerminatorCore
import TerminatorFeatures
import TerminatorPersistence
import TerminatorSecurity

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
            modelContainer = container
            _appModel = State(
                initialValue: TerminatorAppModel(
                    capabilities: .current,
                    hostRepository: store,
                    credentialRepository: store,
                    historyRepository: store,
                    secretStore: secretStore,
                    dockerService: DemoDockerService()
                )
            )
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
