#if os(macOS)
import Foundation
import TerminatorCore
import TerminatorPersistence
import TerminatorSecurity
import TerminatorSSH

@main
enum TerminatorConnectionServiceMain {
    static func main() async {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "connect":
                await connectOnce()
                return
            case "mcp":
                TerminatorMCPServer.run()
                return
            default:
                break
            }
            try await run()
        } catch {
            FileHandle.standardError.write(Data("terminator-service: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func connectOnce() async {
        guard let hostID = CommandLine.arguments.dropFirst(2).first.flatMap(UUID.init(uuidString:)) else {
            FileHandle.standardError.write(Data("terminator-service: usage: terminator-service connect <host-id>\n".utf8))
            Foundation.exit(1)
        }
        let terminal = CommandLine.arguments.dropFirst(3).first.flatMap(TerminalApplication.init(rawValue:)) ?? .terminal
        do {
            guard AccessPreferencesStore.load().cliEnabled else { throw ConnectionServiceError.cliDisabled }
            try await ConnectionServiceClient().connect(hostID: hostID, terminal: terminal)
        } catch {
            FileHandle.standardError.write(Data("terminator-service: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
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
        await prompting.attach(runtime)
        try await runtime.start()
        try await runtime.waitUntilStopped()
    }
}
#else
@main
enum TerminatorConnectionServiceMain {
    static func main() {}
}
#endif
