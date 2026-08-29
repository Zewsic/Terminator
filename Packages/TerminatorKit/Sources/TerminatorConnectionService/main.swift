#if os(macOS)
import Foundation
import TerminatorCore
import TerminatorPersistence
import TerminatorSecurity
import TerminatorSSH

@main
enum TerminatorConnectionServiceMain {
    static func main() {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "connect":
                connectOnce()
                return
            case "mcp":
                TerminatorMCPServer.run()
                return
            default:
                break
            }
            try run()
        } catch {
            FileHandle.standardError.write(Data("terminator-service: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
        RunLoop.main.run()
    }

    private static func connectOnce() {
        guard let hostID = CommandLine.arguments.dropFirst(2).first.flatMap(UUID.init(uuidString:)) else {
            FileHandle.standardError.write(Data("terminator-service: usage: terminator-service connect <host-id>\n".utf8))
            Foundation.exit(1)
        }
        let terminal = CommandLine.arguments.dropFirst(3).first.flatMap(TerminalApplication.init(rawValue:)) ?? .terminal
        Task {
            do {
                guard AccessPreferencesStore.load().cliEnabled else { throw ConnectionServiceError.cliDisabled }
                try await ConnectionServiceClient().connect(hostID: hostID, terminal: terminal)
                Foundation.exit(0)
            } catch {
                FileHandle.standardError.write(Data("terminator-service: \(error.localizedDescription)\n".utf8))
                Foundation.exit(1)
            }
        }
        RunLoop.main.run()
    }

    private static func run() throws {
        let container = try TerminatorSchema.makeContainer()
        let store = TerminatorStore(modelContainer: container)
        let secretStore = KeychainSecretStore(service: "pro.zewsic.terminator.secrets")
        let accessKeyService = AppleAccessKeyService()
        let authenticationResolver = AuthenticationResolver(
            credentialRepository: store, identityRepository: store, secretStore: secretStore
        )
        let coordinator = NIOSSHConnectionCoordinator(
            authenticationResolver: authenticationResolver,
            accessKeyService: accessKeyService,
            knownHosts: store,
            logRepository: store,
            secretStore: secretStore,
            logBaseURL: ConnectionServicePaths.sessionLogURL
        )
        let broker = TerminalAttachBroker(
            coordinator: coordinator, directoryURL: ConnectionServicePaths.attachDirectoryURL
        )
        let prompting = ConnectionServicePrompter()
        let launcher = ServiceTerminalLauncher()
        let runtime = ConnectionServiceRuntime(
            coordinator: coordinator,
            broker: broker,
            hostRepository: store,
            prompting: prompting,
            terminalLauncher: launcher
        )
        Task {
            await prompting.attach(runtime)
            try await runtime.start()
        }
    }
}
#else
@main
enum TerminatorConnectionServiceMain {
    static func main() {}
}
#endif
