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
            setPhase(.connected, for: host.id)
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
        reconnectTasks[hostID]?.cancel()
        reconnectTasks[hostID] = nil
        let ids = sessions.filter { $0.value.hostID == hostID }.map(\.key)
        for id in ids { await closeSession(id: id) }
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

    func createSessionChannel(transport: Channel, sessionID: UUID, size: TerminalSize) async throws -> Channel {
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

    func channelClosed(sessionID: UUID, exitedNormally: Bool) async {
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

    func closeSession(id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if session.channel.isActive { try? await session.channel.close().get() }
        await session.log.finish()
        session.continuation.finish()
        if !sessions.values.contains(where: { $0.hostID == session.hostID }),
           let pool = pools.removeValue(forKey: session.hostID) {
            pool.intentionalClose = true
            try? await pool.channel.close().get()
            setPhase(.disconnected, for: session.hostID)
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

}
