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
        case .authenticationFailed: "The server rejected every configured authentication method."
        case .authenticationRejected(let availableMethods):
            if availableMethods.isEmpty {
                "Authentication failed. The server did not offer a supported authentication method."
            } else {
                "Authentication failed. The server accepts: \(availableMethods.joined(separator: ", "))."
            }
        case .authenticationTimedOut: "Authentication timed out. The server did not complete the SSH login."
        case .hostKeyRejected: "The server host key was not trusted."
        case .unsupportedRSA: "RSA authentication requires the Terminator RFC 8332 transport patch."
        case .sessionUnavailable: "The SSH session is no longer available."
        }
    }
}

public actor NIOSSHConnectionCoordinator: SSHConnectionCoordinating {
    private final class Pool: @unchecked Sendable {
        let host: HostProfile
        let prompting: any SSHConnectionPrompting
        var channel: Channel
        var intentionalClose = false

        init(host: HostProfile, prompting: any SSHConnectionPrompting, channel: Channel) {
            self.host = host; self.prompting = prompting; self.channel = channel
        }
    }

    private struct ActiveSession {
        var hostID: UUID
        var terminal: TerminalApplication
        var size: TerminalSize
        var channel: Channel
        var continuation: AsyncStream<SSHSessionEvent>.Continuation
        var log: SessionLogWriter
    }

    private let group: MultiThreadedEventLoopGroup
    private let authenticationResolver: any AuthenticationResolving
    private let accessKeyService: any AccessKeyService
    private let knownHosts: any KnownHostRepository
    private let logRepository: any SessionLogRepository
    private let secretStore: any SecretStore
    private let logBaseURL: URL
    private var pools: [UUID: Pool] = [:]
    private var phases: [UUID: SSHConnectionPhase] = [:]
    private var sessions: [UUID: ActiveSession] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var prepareTasks: [UUID: Task<Void, Error>] = [:]

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

    private func establish(host: HostProfile, prompting: any SSHConnectionPrompting) async throws {
        phases[host.id] = .resolving
        let identity = try await authenticationResolver.resolve(host: host, prompting: prompting)
        phases[host.id] = .authenticating
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
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: hostDelegate)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
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
            // A live TCP channel is not yet an authenticated SSH connection.
            // `.connected` is set only after the first child session channel
            // has been accepted by the server.
            phases[host.id] = .authenticating
        } catch {
            phases[host.id] = .failed(message: error.localizedDescription)
            throw error
        }
    }

    public func openSession(
        host: HostProfile,
        terminal: TerminalApplication,
        size: TerminalSize
    ) async throws -> SSHSessionHandle {
        guard let pool = pools[host.id], pool.channel.isActive else { throw SSHTransportError.sessionUnavailable }
        let id = UUID()
        let (stream, continuation) = AsyncStream<SSHSessionEvent>.makeStream()
        let log = try await SessionLogWriter.create(
            host: host, terminal: terminal, repository: logRepository,
            secretStore: secretStore, baseURL: logBaseURL
        )
        do {
            let child = try await createSessionChannel(
                transport: pool.channel, sessionID: id, size: size
            )
            sessions[id] = ActiveSession(
                hostID: host.id, terminal: terminal, size: size, channel: child,
                continuation: continuation, log: log
            )
            phases[host.id] = .connected
            let logID = await log.metadata.id
            return SSHSessionHandle(
                id: id, logID: logID, events: stream,
                writer: { [weak self] data in try await self?.write(data, sessionID: id) },
                resizer: { [weak self] size in try await self?.resize(size, sessionID: id) },
                closer: { [weak self] in await self?.closeSession(id: id) }
            )
        } catch {
            phases[host.id] = .failed(message: error.localizedDescription)
            await log.finish()
            continuation.finish()
            throw error
        }
    }

    public func state(for hostID: UUID) -> SSHConnectionPhase { phases[hostID] ?? .disconnected }

    public func disconnect(hostID: UUID) async {
        reconnectTasks[hostID]?.cancel()
        reconnectTasks[hostID] = nil
        let ids = sessions.filter { $0.value.hostID == hostID }.map(\.key)
        for id in ids { await closeSession(id: id) }
        if let pool = pools.removeValue(forKey: hostID) {
            pool.intentionalClose = true
            try? await pool.channel.close().get()
        }
        phases[hostID] = .disconnected
    }

    private func authenticationOffers(
        _ identity: ResolvedSSHIdentity,
        prompting: any SSHConnectionPrompting
    ) async throws -> [AuthOffer] {
        var result: [AuthOffer] = []
        for method in identity.methods {
            switch method {
            case .password(_, let value):
                guard let password = String(data: value, encoding: .utf8) else { continue }
                result.append(.password(password))
            case .softwareKey(_, let privateMaterial, let passphrase):
                let material = try await accessKeyService.decodeSoftwareKey(
                    privateMaterial: privateMaterial, passphrase: passphrase ?? ""
                )
                result.append(.privateKey(try makePrivateKey(material)))
            case .secureEnclaveKey(_, let reference):
                await prompting.requiresUserAttention(reason: "Touch ID is required to use this SSH key.")
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: reference)
                result.append(.privateKey(NIOSSHPrivateKey(secureEnclaveP256Key: key)))
            }
        }
        guard !result.isEmpty else { throw SSHTransportError.authenticationFailed }
        return result
    }

    private func makePrivateKey(_ material: SSHPrivateKeyMaterial) throws -> NIOSSHPrivateKey {
        switch material {
        case .ed25519(let seed):
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
        case .ecdsa(.p256, let scalar):
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case .ecdsa(.p384, let scalar):
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case .ecdsa(.p521, let scalar):
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: scalar))
        case .rsa(let modulus, let exponent, let privateExponent, let p, let q, _):
            let key = try _RSA.Signing.PrivateKey(
                n: modulus, e: exponent, d: privateExponent, p: p, q: q
            )
            return NIOSSHPrivateKey(rsaKey: key)
        }
    }

    private func createSessionChannel(transport: Channel, sessionID: UUID, size: TerminalSize) async throws -> Channel {
        let bridge = SessionChannelBridge(
            size: size,
            onEvent: { [weak self] event in Task { await self?.receive(event, sessionID: sessionID) } },
            onClose: { [weak self] exitedNormally in
                Task { await self?.channelClosed(sessionID: sessionID, exitedNormally: exitedNormally) }
            }
        )
        let child = transport.eventLoop.flatSubmit {
            transport.pipeline.handler(type: NIOSSHHandler.self).flatMap { handler in
                let promise = transport.eventLoop.makePromise(of: Channel.self)
                handler.createChannel(promise, channelType: .session) { channel, type in
                    guard type == .session else {
                        return channel.eventLoop.makeFailedFuture(SSHTransportError.sessionUnavailable)
                    }
                    return channel.pipeline.addHandlers(bridge)
                }
                return promise.futureResult
            }
        }
        return try await child.get()
    }

    private func write(_ data: Data, sessionID: UUID) async throws {
        guard let session = sessions[sessionID], session.channel.isActive else { throw SSHTransportError.sessionUnavailable }
        var buffer = session.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await session.channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    private func resize(_ size: TerminalSize, sessionID: UUID) async throws {
        guard var session = sessions[sessionID], session.channel.isActive else { throw SSHTransportError.sessionUnavailable }
        session.size = size
        sessions[sessionID] = session
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0
        )
        try await session.channel.triggerUserOutboundEvent(event).get()
    }

    private func receive(_ event: SSHSessionEvent, sessionID: UUID) async {
        guard let session = sessions[sessionID] else { return }
        session.continuation.yield(event)
        let logged: Bool
        switch event {
        case .stdout(let data): logged = await session.log.append(kind: .stdout, data: data)
        case .stderr(let data): logged = await session.log.append(kind: .stderr, data: data)
        case .status(let message): logged = await session.log.append(kind: .status, data: Data(message.utf8))
        case .exited: logged = true
        }
        if !logged {
            session.continuation.yield(.status("\r\n[Terminator: session logging failed; this log is incomplete]\r\n"))
        }
    }

    private func channelClosed(sessionID: UUID, exitedNormally: Bool) async {
        guard let session = sessions[sessionID] else { return }
        if exitedNormally {
            await closeSession(id: sessionID)
            return
        }
        // A transport failure closes all child channels before the parent close
        // notification is guaranteed to reach this actor. Give that notification
        // one event-loop turn, then retain the logical session for reconnect.
        try? await Task.sleep(for: .milliseconds(100))
        if pools[session.hostID]?.channel.isActive != true {
            return
        }
        // An interactive shell disappearing without an exit-status is a channel
        // failure, not a user exit. Closing the pooled transport gives every
        // attached channel the same reconnect path and prevents a dead renderer.
        if let pool = pools[session.hostID], !pool.intentionalClose {
            try? await pool.channel.close().get()
        }
    }

    private func closeSession(id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if session.channel.isActive { try? await session.channel.close().get() }
        await session.log.finish()
        session.continuation.finish()
        if !sessions.values.contains(where: { $0.hostID == session.hostID }),
           let pool = pools.removeValue(forKey: session.hostID) {
            pool.intentionalClose = true
            try? await pool.channel.close().get()
            phases[session.hostID] = .disconnected
        }
    }

    private func transportClosed(hostID: UUID, error: Error?) async {
        guard let pool = pools[hostID], !pool.intentionalClose else { return }
        pools[hostID] = nil
        guard sessions.values.contains(where: { $0.hostID == hostID }) else {
            phases[hostID] = .disconnected
            return
        }
        guard reconnectTasks[hostID] == nil else { return }
        await broadcastStatus("\r\n[Terminator: connection lost; reconnecting…]\r\n", hostID: hostID)
        reconnectTasks[hostID] = Task { [weak self] in await self?.reconnect(host: pool.host, prompting: pool.prompting) }
    }

    private func reconnect(host: HostProfile, prompting: any SSHConnectionPrompting) async {
        var attempt = 0
        while !Task.isCancelled && sessions.values.contains(where: { $0.hostID == host.id }) {
            attempt += 1
            phases[host.id] = .reconnecting(attempt: attempt)
            do {
                try await establish(host: host, prompting: prompting)
                guard let transport = pools[host.id]?.channel else { throw SSHTransportError.sessionUnavailable }
                let ids = sessions.filter { $0.value.hostID == host.id }.map(\.key)
                for id in ids {
                    guard var session = sessions[id] else { continue }
                    session.channel = try await createSessionChannel(transport: transport, sessionID: id, size: session.size)
                    sessions[id] = session
                    await session.log.markReconnect()
                    session.continuation.yield(.status("\r\n--- Terminator reconnected: new remote shell ---\r\n"))
                }
                phases[host.id] = .connected
                reconnectTasks[host.id] = nil
                return
            } catch {
                phases[host.id] = .failed(message: error.localizedDescription)
                let seconds = min(30.0, pow(2.0, Double(min(attempt - 1, 5))))
                await broadcastStatus(
                    "[Terminator: reconnect attempt \(attempt) failed; retrying in \(Int(seconds))s]\r\n",
                    hostID: host.id
                )
                try? await Task.sleep(for: .seconds(seconds + Double.random(in: 0 ... 0.5)))
            }
        }
        reconnectTasks[host.id] = nil
    }

    private func broadcastStatus(_ message: String, hostID: UUID) async {
        let data = Data(message.utf8)
        for session in sessions.values where session.hostID == hostID {
            session.continuation.yield(.status(message))
            _ = await session.log.append(kind: .status, data: data)
        }
    }

    private static func endpoint(for host: HostProfile) -> String {
        let normalized = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return host.port == 22 ? normalized : "[\(normalized)]:\(host.port)"
    }
}

private enum AuthOffer: @unchecked Sendable {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

private final class OrderedAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let onExhausted: @Sendable (NIOSSHAvailableUserAuthenticationMethods) -> Void
    private let lock = NSLock()
    private var offers: [AuthOffer]

    init(
        username: String,
        offers: [AuthOffer],
        onExhausted: @escaping @Sendable (NIOSSHAvailableUserAuthenticationMethods) -> Void
    ) {
        self.username = username
        self.offers = offers
        self.onExhausted = onExhausted
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        defer { lock.unlock() }
        while !offers.isEmpty {
            let offer = offers.removeFirst()
            switch offer {
            case .password(let password) where availableMethods.contains(.password):
                nextChallengePromise.succeed(.init(
                    username: username, serviceName: "ssh-connection", offer: .password(.init(password: password))
                ))
                return
            case .privateKey(let key) where availableMethods.contains(.publicKey):
                nextChallengePromise.succeed(.init(
                    username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))
                ))
                return
            default: continue
            }
        }
        let error = SSHTransportError.authenticationRejected(
            availableMethods: availableMethods.terminatorDisplayNames
        )
        onExhausted(availableMethods)
        nextChallengePromise.fail(error)
    }
}

private extension NIOSSHAvailableUserAuthenticationMethods {
    var terminatorDisplayNames: [String] {
        var result: [String] = []
        if contains(.password) { result.append("password") }
        if contains(.publicKey) { result.append("public key") }
        if contains(.hostBased) { result.append("host-based authentication") }
        return result
    }
}

private final class AuthenticationResultBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    let futureResult: EventLoopFuture<Void>
    private let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var completed = false

    init(eventLoop: EventLoop) {
        promise = eventLoop.makePromise(of: Void.self)
        futureResult = promise.futureResult
    }

    func fail(_ error: Error) {
        complete { promise.fail(error) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete { promise.succeed(()) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(SSHTransportError.authenticationFailed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.fireErrorCaught(error)
    }

    private func complete(_ body: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        body()
    }
}

private final class StrictHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: String
    private let repository: any KnownHostRepository
    private let prompting: any SSHConnectionPrompting

    init(endpoint: String, repository: any KnownHostRepository, prompting: any SSHConnectionPrompting) {
        self.endpoint = endpoint; self.repository = repository; self.prompting = prompting
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        Task {
            do {
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2, let blob = Data(base64Encoded: String(fields[1])) else {
                    throw SSHTransportError.hostKeyRejected
                }
                let fingerprint = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
                let presented = KnownHostKey(
                    endpoint: endpoint, algorithm: String(fields[0]), publicKey: blob, fingerprint: fingerprint
                )
                if let stored = try await repository.knownHost(endpoint: endpoint, algorithm: presented.algorithm) {
                    guard stored.publicKey == blob else {
                        if try await prompting.confirmChangedHost(previous: stored, presented: presented) {
                            var replacement = presented
                            replacement.id = stored.id; replacement.createdAt = stored.createdAt
                            try await repository.saveKnownHost(replacement)
                            validationCompletePromise.succeed(())
                        } else { validationCompletePromise.fail(SSHTransportError.hostKeyRejected) }
                        return
                    }
                    validationCompletePromise.succeed(())
                } else if try await prompting.trustNewHost(presented) {
                    try await repository.saveKnownHost(presented)
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(SSHTransportError.hostKeyRejected)
                }
            } catch { validationCompletePromise.fail(error) }
        }
    }
}

private final class TransportCloseBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let onClose: @Sendable (Error?) -> Void
    init(onClose: @escaping @Sendable (Error?) -> Void) { self.onClose = onClose }
    func channelInactive(context: ChannelHandlerContext) { onClose(nil); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { onClose(error); context.close(promise: nil) }
}

private final class SessionChannelBridge: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    private let size: TerminalSize
    private let onEvent: @Sendable (SSHSessionEvent) -> Void
    private let onClose: @Sendable (Bool) -> Void
    private var receivedExitStatus = false

    init(size: TerminalSize, onEvent: @escaping @Sendable (SSHSessionEvent) -> Void, onClose: @escaping @Sendable (Bool) -> Void) {
        self.size = size; self.onEvent = onEvent; self.onClose = onClose
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = value.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        onEvent(value.type == .stdErr ? .stderr(Data(bytes)) : .stdout(Data(bytes)))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            receivedExitStatus = true
            onEvent(.exited(Int(exit.exitStatus)))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose(receivedExitStatus)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { onEvent(.status(error.localizedDescription)); context.close(promise: nil) }
}
