import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOSSH
import TerminatorCore
import TerminatorSecurity

public enum SSHTransportError: LocalizedError, Sendable {
    case authenticationFailed
    case authenticationRejected(availableMethods: [String])
    case authenticationTimedOut
    case hostKeyRejected
    case unsupportedRSA
    case sessionUnavailable

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed: SSHL10n.text(.errorAuthenticationFailed)
        case .authenticationRejected(let availableMethods):
            if availableMethods.isEmpty {
                "Authentication failed. The server did not offer a supported authentication method."
            } else {
                "Authentication failed. The server accepts: \(availableMethods.joined(separator: ", "))."
            }
        case .authenticationTimedOut: SSHL10n.text(.errorAuthenticationTimedOut)
        case .hostKeyRejected: SSHL10n.text(.errorHostKeyRejected)
        case .unsupportedRSA: SSHL10n.text(.errorUnsupportedRSA)
        case .sessionUnavailable: SSHL10n.text(.errorSessionUnavailable)
        }
    }
}

public actor NIOSSHConnectionCoordinator: SSHConnectionCoordinating {
    final class Pool: @unchecked Sendable {
        let host: HostProfile
        let prompting: any SSHConnectionPrompting
        var channel: Channel
        var intentionalClose = false

        init(host: HostProfile, prompting: any SSHConnectionPrompting, channel: Channel) {
            self.host = host; self.prompting = prompting; self.channel = channel
        }
    }

    struct ActiveSession {
        var hostID: UUID
        var terminal: TerminalApplication
        var size: TerminalSize
        var remoteCommand: String?
        var channel: Channel
        var continuation: AsyncStream<SSHSessionEvent>.Continuation
        var log: SessionLogWriter
    }

    let group: MultiThreadedEventLoopGroup
    let authenticationResolver: any AuthenticationResolving
    let accessKeyService: any AccessKeyService
    let knownHosts: any KnownHostRepository
    let logRepository: any SessionLogRepository
    let secretStore: any SecretStore
    let logBaseURL: URL
    var pools: [UUID: Pool] = [:]
    var phases: [UUID: SSHConnectionPhase] = [:]
    var sessions: [UUID: ActiveSession] = [:]
    var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    var prepareTasks: [UUID: Task<Void, Error>] = [:]
    var retainedHosts: Set<UUID> = []
    var stateContinuations: [UUID: [UUID: AsyncStream<SSHConnectionPhase>.Continuation]] = [:]
    let forwardRouter = TunnelForwardRouter()
    var desiredTunnels: [UUID: TunnelProfile] = [:]
    var runningTunnels: [UUID: RunningTunnel] = [:]
    var tunnelPhaseHandler: (@Sendable (UUID, SSHConnectionPhase) -> Void)?

    public init(
        authenticationResolver: any AuthenticationResolving,
        accessKeyService: any AccessKeyService,
        knownHosts: any KnownHostRepository,
        logRepository: any SessionLogRepository,
        secretStore: any SecretStore,
        logBaseURL: URL,
        threadCount: Int = 1
    ) {
        self.authenticationResolver = authenticationResolver
        self.accessKeyService = accessKeyService
        self.knownHosts = knownHosts
        self.logRepository = logRepository
        self.secretStore = secretStore
        self.logBaseURL = logBaseURL
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, threadCount))
    }

    deinit { try? group.syncShutdownGracefully() }

    public func prepare(host: HostProfile, prompting: any SSHConnectionPrompting) async throws {
        if let existing = pools[host.id], existing.channel.isActive {
            if existing.host.hostname == host.hostname,
               existing.host.port == host.port,
               existing.host.authentication == host.authentication { return }
            await disconnect(hostID: host.id)
        }
        if let pending = prepareTasks[host.id] { return try await pending.value }
        let task = Task { try await self.establish(host: host, prompting: prompting) }
        prepareTasks[host.id] = task
        do {
            try await task.value
            prepareTasks[host.id] = nil
        } catch {
            prepareTasks[host.id] = nil
            throw error
        }
    }

    func establish(host: HostProfile, prompting: any SSHConnectionPrompting) async throws {
        setPhase(.resolving, for: host.id)
        let identity = try await authenticationResolver.resolve(host: host, prompting: prompting)
        setPhase(.authenticating, for: host.id)
        let offers = try await authenticationOffers(identity, prompting: prompting)
        let authenticationResult = AuthenticationResultBridge(eventLoop: group.next())
        let authDelegate = OrderedAuthenticationDelegate(
            username: identity.username,
            offers: offers,
            onExhausted: { availableMethods in
                authenticationResult.fail(
                    SSHTransportError.authenticationRejected(
                        availableMethods: availableMethods.terminatorDisplayNames
                    )
                )
            }
        )
        let hostDelegate = StrictHostKeyDelegate(
            endpoint: Self.endpoint(for: host), repository: knownHosts, prompting: prompting
        )
        let closeBridge = TransportCloseBridge { [weak self] error in
            Task { await self?.transportClosed(hostID: host.id, error: error) }
        }
        let router = forwardRouter
        let connectedHostID = host.id
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: hostDelegate)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, type in
                            router.accept(hostID: connectedHostID, channel: child, type: type)
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(authenticationResult)
                    try channel.pipeline.syncOperations.addHandler(closeBridge)
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            // SO_KEEPALIVE alone inherits macOS' very long system defaults. A
            // disconnected laptop could therefore leave an attach terminal
            // looking frozen for hours before channelInactive was delivered.
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPALIVE), value: 10)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPINTVL), value: 5)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPCNT), value: 3)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        do {
            let channel = try await bootstrap.connect(host: host.hostname, port: host.port).get()
            let authenticationTimeout = channel.eventLoop.scheduleTask(in: .seconds(30)) {
                authenticationResult.fail(SSHTransportError.authenticationTimedOut)
                channel.close(promise: nil)
            }
            do {
                try await authenticationResult.futureResult.get()
                authenticationTimeout.cancel()
            } catch {
                authenticationTimeout.cancel()
                try? await channel.close().get()
                throw error
            }
            pools[host.id] = Pool(host: host, prompting: prompting, channel: channel)
            retainedHosts.insert(host.id)
            // A live TCP channel is not yet an authenticated SSH connection.
            // `.connected` is set only after the first child session channel
            // has been accepted by the server. A retained transport with no
            // attached terminal still counts as connected for the host list.
            setPhase(.connected, for: host.id)
        } catch {
            setPhase(.failed(message: error.localizedDescription), for: host.id)
            throw error
        }
    }

}
