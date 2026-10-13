import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOSSH
import TerminatorCore
import TerminatorSecurity

extension NIOSSHConnectionCoordinator {
    public func openSession(
        host: HostProfile,
        terminal: TerminalApplication,
        size: TerminalSize,
        persistence: SessionPersistence,
        command: String? = nil
    ) async throws -> SSHSessionHandle {
        try await openSession(
            host: host,
            terminal: terminal,
            size: size,
            persistence: persistence,
            command: command,
            connectCommands: nil
        )
    }

    public func openSession(
        host: HostProfile,
        terminal: TerminalApplication,
        size: TerminalSize,
        persistence: SessionPersistence,
        command: String? = nil,
        connectCommands: String?
    ) async throws -> SSHSessionHandle {
        guard let pool = pools[host.id], pool.channel.isActive else { throw SSHTransportError.sessionUnavailable }
        let id = UUID()
        let (stream, continuation) = AsyncStream<SSHSessionEvent>.makeStream()
        let log = try await SessionLogWriter.create(
            host: host, terminal: terminal, repository: logRepository,
            secretStore: secretStore, baseURL: logBaseURL
        )
        do {
            let remoteCommand = command ?? SessionLaunchCommand.remoteCommand(
                sessionID: id,
                persistence: persistence,
                connectCommands: connectCommands ?? host.connectCommands,
                shell: host.remoteShell
            )
            let child = try await createSessionChannel(
                transport: pool.channel, sessionID: id, size: size, remoteCommand: remoteCommand
            )
            sessions[id] = ActiveSession(
                hostID: host.id, terminal: terminal, size: size, remoteCommand: remoteCommand, channel: child,
                continuation: continuation, log: log
            )
            publishLink(for: host.id)
            let logID = await log.metadata.id
            return SSHSessionHandle(
                id: id, logID: logID, events: stream,
                writer: { [weak self] data in try await self?.write(data, sessionID: id) },
                resizer: { [weak self] size in try await self?.resize(size, sessionID: id) },
                closer: { [weak self] in await self?.closeSession(id: id) }
            )
        } catch {
            setPhase(.failed(message: error.localizedDescription), for: host.id)
            await log.finish()
            continuation.finish()
            throw error
        }
    }

    public func listedSessions() -> [(id: UUID, hostID: UUID)] {
        sessions.map { (id: $0.key, hostID: $0.value.hostID) }
    }

    public func writeToSession(_ data: Data, id: UUID) async throws {
        try await write(data, sessionID: id)
    }

    public func state(for hostID: UUID) -> SSHConnectionPhase { phases[hostID] ?? .disconnected }

    public func states(for hostID: UUID) -> AsyncStream<SSHConnectionPhase> {
        let observerID = UUID()
        return AsyncStream { continuation in
            stateContinuations[hostID, default: [:]][observerID] = continuation
            continuation.yield(phases[hostID] ?? .disconnected)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateObserver(observerID, hostID: hostID) }
            }
        }
    }

    public func disconnect(hostID: UUID) async {
        await stopTunnels(touching: hostID)
        retainedHosts.remove(hostID)
        reconnectTasks[hostID]?.cancel()
        reconnectTasks[hostID] = nil
        let ids = sessions.filter { $0.value.hostID == hostID }.map(\.key)
        for id in ids { await closeSession(id: id) }
        await closeDockerShell(hostID: hostID)
        await desiredWork?.removeTerminals(hostID: hostID)
        if let pool = pools.removeValue(forKey: hostID) {
            pool.intentionalClose = true
            try? await pool.channel.close().get()
        }
        setPhase(.disconnected, for: hostID)
        finishStateObservers(for: hostID)
    }

    func authenticationOffers(
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

    func makePrivateKey(_ material: SSHPrivateKeyMaterial) throws -> NIOSSHPrivateKey {
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

    func createSessionChannel(
        transport: Channel,
        sessionID: UUID,
        size: TerminalSize,
        remoteCommand: String?
    ) async throws -> Channel {
        let bridge = SessionChannelBridge(
            size: size,
            remoteCommand: remoteCommand,
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

    func write(_ data: Data, sessionID: UUID) async throws {
        guard let session = sessions[sessionID], session.channel.isActive else { throw SSHTransportError.sessionUnavailable }
        var buffer = session.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await session.channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    func resize(_ size: TerminalSize, sessionID: UUID) async throws {
        guard var session = sessions[sessionID], session.channel.isActive else { throw SSHTransportError.sessionUnavailable }
        session.size = size
        sessions[sessionID] = session
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0
        )
        try await session.channel.triggerUserOutboundEvent(event).get()
    }

    func receive(_ event: SSHSessionEvent, sessionID: UUID) async {
        guard sessions[sessionID] != nil else { return }
        emit(event, sessionID: sessionID)
        guard let session = sessions[sessionID] else { return }
        let logged: Bool
        switch event {
        case .stdout(let data): logged = await session.log.append(kind: .stdout, data: data)
        case .stderr(let data): logged = await session.log.append(kind: .stderr, data: data)
        case .status(let message): logged = await session.log.append(kind: .status, data: Data(message.utf8))
        case .exited: logged = true
        }
        if !logged {
            emit(.status("\r\n[Terminator: session logging failed; this log is incomplete]\r\n"), sessionID: sessionID)
        }
    }

    func emit(_ event: SSHSessionEvent, sessionID: UUID) {
        guard let session = sessions[sessionID] else { return }
        session.continuation.yield(event)
        for listener in session.listeners.values { listener.yield(event) }
    }

    func subscribe(sessionID: UUID) -> (UUID, AsyncStream<SSHSessionEvent>)? {
        guard var session = sessions[sessionID] else { return nil }
        let listenerID = UUID()
        let (stream, continuation) = AsyncStream<SSHSessionEvent>.makeStream()
        session.listeners[listenerID] = continuation
        sessions[sessionID] = session
        return (listenerID, stream)
    }

    func unsubscribe(sessionID: UUID, listenerID: UUID) {
        guard var session = sessions[sessionID] else { return }
        session.listeners.removeValue(forKey: listenerID)?.finish()
        sessions[sessionID] = session
    }

    func channelClosed(sessionID: UUID, exitedNormally: Bool) async {
        guard sessions[sessionID] != nil else { return }
        if exitedNormally {
            await closeSession(id: sessionID)
            return
        }
        // A transport failure closes all child channels before the parent close
        // notification is guaranteed to reach this actor. Give that notification
        // one event-loop turn, then retain the logical session for reconnect.
        try? await Task.sleep(for: .milliseconds(100))
        guard let session = sessions[sessionID] else { return }
        // The child channel is gone. Reconnect restores the transport, not this
        // shell, so the log must not stay active until the next launch.
        await session.log.finish(as: .incomplete)
        if pools[session.hostID]?.channel.isActive != true {
            return
        }
        if let pool = pools[session.hostID], !pool.intentionalClose {
            try? await pool.channel.close().get()
        }
    }

    func closeSession(id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if session.channel.isActive { try? await session.channel.close().get() }
        await session.log.finish()
        session.continuation.finish()
        for listener in session.listeners.values { listener.finish() }
        await sessionClosedHandler?(id)
        if retainedHosts.contains(session.hostID), pools[session.hostID]?.channel.isActive == true {
            publishLink(for: session.hostID)
        }
    }

    /// `.connected` while an interactive session exists, `.agent` while only the transport is up.
    func publishLink(for hostID: UUID) {
        if sessions.contains(where: { $0.value.hostID == hostID }) {
            setPhase(.connected, for: hostID)
        } else if pools[hostID]?.channel.isActive == true {
            setPhase(.agent, for: hostID)
        }
    }

    func setPhase(_ phase: SSHConnectionPhase, for hostID: UUID) {
        phases[hostID] = phase
        if let observers = stateContinuations[hostID] {
            for continuation in observers.values { continuation.yield(phase) }
        }
    }

    func removeStateObserver(_ observerID: UUID, hostID: UUID) {
        stateContinuations[hostID]?[observerID] = nil
        if stateContinuations[hostID]?.isEmpty == true {
            stateContinuations[hostID] = nil
        }
    }

    func finishStateObservers(for hostID: UUID) {
        guard let observers = stateContinuations.removeValue(forKey: hostID) else { return }
        for continuation in observers.values { continuation.finish() }
    }

    public func exec(host: HostProfile, command: String) async throws -> SSHExecResult {
        try await exec(host: host, command: command, timeout: .seconds(6))
    }

    public func exec(host: HostProfile, command: String, timeout: Duration, partialOnTimeout: Bool = false) async throws -> SSHExecResult {
        guard let pool = pools[host.id], pool.channel.isActive else {
            throw SSHTransportError.sessionUnavailable
        }
        let collector = ExecCollector()
        let child = try await createExecChannel(transport: pool.channel, command: command, collector: collector)
        return try await collector.value(timeout: timeout, channel: child, partialOnTimeout: partialOnTimeout)
    }

    func createExecChannel(
        transport: Channel,
        command: String,
        collector: ExecCollector
    ) async throws -> Channel {
        let child = transport.eventLoop.flatSubmit {
            transport.pipeline.handler(type: NIOSSHHandler.self).flatMap { handler in
                let promise = transport.eventLoop.makePromise(of: Channel.self)
                handler.createChannel(promise, channelType: .session) { channel, type in
                    guard type == .session else {
                        return channel.eventLoop.makeFailedFuture(SSHTransportError.sessionUnavailable)
                    }
                    let bridge = SessionChannelBridge(
                        size: TerminalSize(columns: 80, rows: 24),
                        remoteCommand: command,
                        onEvent: { event in
                            collector.append(event)
                            if case .exited(let code) = event {
                                collector.noteExit(code ?? 0)
                            }
                        },
                        onClose: { _ in collector.noteExit(0) }
                    )
                    return channel.pipeline.addHandler(bridge).flatMap { _ in
                        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    }
                }
                return promise.futureResult
            }
        }
        return try await child.get()
    }
}

final class ExecCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var notedExit: Int?
    private var continuation: CheckedContinuation<SSHExecResult, Error>?
    private var result: Result<SSHExecResult, Error>?

    func append(_ event: SSHSessionEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .stdout(let data):
            stdout.append(data)
            if stdout.count > 65_536 { stdout = Data(stdout.suffix(65_536)) }
        case .stderr(let data):
            stderr.append(data)
            if stderr.count > 16_384 { stderr = Data(stderr.suffix(16_384)) }
        case .status(let message):
            stderr.append(Data(message.utf8))
        case .exited:
            break
        }
    }

    func noteExit(_ code: Int) {
        lock.lock()
        if notedExit != nil {
            lock.unlock()
            return
        }
        notedExit = code
        lock.unlock()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            self.complete(exitCode: code)
        }
    }

    func complete(exitCode: Int) {
        lock.lock()
        let code = notedExit ?? exitCode
        let value = SSHExecResult(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            exitCode: code
        )
        lock.unlock()
        finish(.success(value))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    func value(timeout: Duration, channel: Channel, partialOnTimeout: Bool = false) async throws -> SSHExecResult {
        try await withThrowingTaskGroup(of: SSHExecResult.self) { group in
            group.addTask { try await self.waitForResult() }
            group.addTask {
                try await Task.sleep(for: timeout)
                if partialOnTimeout {
                    let partial = self.partial(exitCode: 124)
                    if channel.isActive { try? await channel.close().get() }
                    return partial
                }
                self.fail(SSHTransportError.sessionUnavailable)
                if channel.isActive { try? await channel.close().get() }
                throw SSHTransportError.sessionUnavailable
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func partial(exitCode: Int) -> SSHExecResult {
        lock.lock()
        let value = SSHExecResult(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            exitCode: exitCode
        )
        lock.unlock()
        finish(.success(value))
        lock.lock()
        let stored = result
        lock.unlock()
        if case .success(let final) = stored { return final }
        return value
    }

    private func waitForResult() async throws -> SSHExecResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func finish(_ outcome: Result<SSHExecResult, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        Task { pending.resume(with: outcome) }
    }
}
