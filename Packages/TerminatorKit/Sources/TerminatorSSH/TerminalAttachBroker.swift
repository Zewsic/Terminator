import Darwin
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import TerminatorCore

public enum AttachBrokerError: LocalizedError, Sendable {
    case expiredOrInvalidToken
    case protocolError

    public var errorDescription: String? {
        switch self {
        case .expiredOrInvalidToken: SSHL10n.text(.errorExpiredOrInvalidToken)
        case .protocolError: SSHL10n.text(.errorProtocolError)
        }
    }
}

public actor TerminalAttachBroker {
    private enum TokenRecord {
        case pending(session: SSHSessionHandle, expiresAt: Date)
        case attached(session: SSHSessionHandle, listenerID: UUID)
        case detached(session: SSHSessionHandle)

        var session: SSHSessionHandle {
            switch self {
            case .pending(let session, _), .attached(let session, _), .detached(let session): session
            }
        }
    }

    fileprivate struct ClaimedAttach: Sendable {
        var session: SSHSessionHandle
        var events: AsyncStream<SSHSessionEvent>
    }

    private let coordinator: NIOSSHConnectionCoordinator
    private let desiredWork: DesiredWorkStore?
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let directoryURL: URL
    private let socketURL: URL
    private var serverChannel: Channel?
    private var records: [String: TokenRecord] = [:]
    private var sessionTokens: [UUID: String] = [:]
    private var graceTasks: [String: Task<Void, Never>] = [:]

    public init(
        coordinator: NIOSSHConnectionCoordinator,
        directoryURL: URL,
        desiredWork: DesiredWorkStore? = nil
    ) {
        self.coordinator = coordinator
        self.desiredWork = desiredWork
        self.directoryURL = directoryURL
        self.socketURL = directoryURL.appending(path: "attach.sock")
    }

    deinit { try? group.syncShutdownGracefully() }

    public func createDescriptor(
        host: HostProfile,
        terminal: TerminalApplication,
        remoteCommand: String? = nil
    ) async throws -> AttachDescriptor {
        try await startIfNeeded()
        await removeExpired()
        let session = try await coordinator.openSession(
            host: host,
            terminal: terminal,
            size: .init(columns: 80, rows: 24),
            persistence: host.sessionPersistence,
            command: remoteCommand
        )
        discardHeadEvents(session)
        let token = Self.token()
        let expiresAt = Date.now.addingTimeInterval(600)
        records[token] = .pending(session: session, expiresAt: expiresAt)
        sessionTokens[session.id] = token
        await desiredWork?.addTerminal(
            DesiredTerminal(token: token, hostID: host.id, columns: 80, rows: 24, remoteCommand: remoteCommand)
        )
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            await self?.expire(token: token)
        }
        return AttachDescriptor(
            sessionID: session.id, socketPath: socketURL.path, token: token, expiresAt: expiresAt
        )
    }

    public func cancel(_ descriptor: AttachDescriptor) async {
        guard let record = records.removeValue(forKey: descriptor.token) else { return }
        graceTasks[descriptor.token]?.cancel()
        graceTasks[descriptor.token] = nil
        await record.session.close()
    }

    public func sessionClosed(_ sessionID: UUID) async {
        guard let token = sessionTokens.removeValue(forKey: sessionID) else { return }
        graceTasks[token]?.cancel()
        graceTasks[token] = nil
        records[token] = nil
        await desiredWork?.removeTerminal(token: token)
    }

    public func restoreDetached(_ terminal: DesiredTerminal, host: HostProfile) {
        Task { [weak self] in await self?.openRestored(terminal, host: host) }
    }

    public func command(for descriptor: AttachDescriptor, helperURL: URL) -> String {
        [helperURL.path, "--socket", descriptor.socketPath, "--token", descriptor.token]
            .map(Self.shellQuote)
            .joined(separator: " ")
    }

    fileprivate func claim(token: String, size: TerminalSize) async throws -> ClaimedAttach {
        await removeExpired()
        graceTasks[token]?.cancel()
        graceTasks[token] = nil
        switch records[token] {
        case .pending(let session, let expiresAt) where expiresAt > .now:
            try await session.resize(to: size)
            guard let (listenerID, events) = await coordinator.subscribe(sessionID: session.id) else {
                throw AttachBrokerError.expiredOrInvalidToken
            }
            records[token] = .attached(session: session, listenerID: listenerID)
            await desiredWork?.updateTerminal(token: token, columns: size.columns, rows: size.rows)
            return ClaimedAttach(session: session, events: events)
        case .detached(let session):
            try await session.resize(to: size)
            guard let (listenerID, events) = await coordinator.subscribe(sessionID: session.id) else {
                throw AttachBrokerError.expiredOrInvalidToken
            }
            records[token] = .attached(session: session, listenerID: listenerID)
            await desiredWork?.updateTerminal(token: token, columns: size.columns, rows: size.rows)
            return ClaimedAttach(session: session, events: events)
        case .attached:
            throw AttachBrokerError.protocolError
        default:
            throw AttachBrokerError.expiredOrInvalidToken
        }
    }

    fileprivate func detach(token: String) async {
        guard case .attached(let session, let listenerID) = records[token] else { return }
        await coordinator.unsubscribe(sessionID: session.id, listenerID: listenerID)
        records[token] = .detached(session: session)
        beginGrace(token)
    }

    private func openRestored(_ terminal: DesiredTerminal, host: HostProfile) async {
        while !Task.isCancelled {
            if await coordinator.isPoolActive(host.id) {
                do {
                    let session = try await coordinator.openSession(
                        host: host,
                        terminal: .terminal,
                        size: TerminalSize(columns: max(1, terminal.columns), rows: max(1, terminal.rows)),
                        persistence: host.sessionPersistence,
                        command: terminal.remoteCommand
                    )
                    discardHeadEvents(session)
                    records[terminal.token] = .detached(session: session)
                    sessionTokens[session.id] = terminal.token
                    beginGrace(terminal.token)
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
            }
            if !(await coordinator.isRetained(host.id)) {
                await desiredWork?.removeTerminal(token: terminal.token)
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func beginGrace(_ token: String) {
        graceTasks[token]?.cancel()
        graceTasks[token] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.graceExpired(token)
        }
    }

    private func graceExpired(_ token: String) async {
        guard case .detached(let session) = records[token] else { return }
        records[token] = nil
        graceTasks[token] = nil
        await session.close()
    }

    private func discardHeadEvents(_ session: SSHSessionHandle) {
        Task { for await _ in session.events {} }
    }

    private func startIfNeeded() async throws {
        guard serverChannel == nil else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try? FileManager.default.removeItem(at: socketURL)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeFailedFuture(AttachBrokerError.protocolError) }
                return channel.pipeline.addHandler(AttachServerHandler(broker: self))
            }
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
        serverChannel = try await bootstrap.bind(unixDomainSocketPath: socketURL.path).get()
        _ = Darwin.chmod(socketURL.path, 0o600)
    }

    private func removeExpired() async {
        let now = Date.now
        let expired = records.compactMap { token, record -> (String, SSHSessionHandle)? in
            if case .pending(let session, let expiresAt) = record, expiresAt <= now {
                return (token, session)
            }
            return nil
        }
        for (token, session) in expired {
            records[token] = nil
            await session.close()
        }
    }

    private func expire(token: String) async {
        guard case .pending(let session, let expiresAt) = records[token], expiresAt <= .now else { return }
        records[token] = nil
        await session.close()
    }

    private static func token() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum AttachFrameType: UInt8 {
    case hello = 1, input = 2, resize = 3, stdout = 10, stderr = 11, status = 12, exit = 13
}

private struct AttachHello: Codable { var version: UInt16; var token: String; var columns: Int; var rows: Int }

private final class AttachServerHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let broker: TerminalAttachBroker
    private var buffer = ByteBuffer()
    private var session: SSHSessionHandle?
    private var token: String?
    private var claimed = false

    init(broker: TerminalAttachBroker) { self.broker = broker }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        do {
            while let frame = try nextFrame() { process(frame, context: context) }
        } catch {
            write(.status, Data("\r\n[Terminator: \(error.localizedDescription)]\r\n".utf8), context: context)
            context.close(promise: nil)
        }
    }

    private func nextFrame() throws -> (AttachFrameType, Data)? {
        guard buffer.readableBytes >= 5 else { return nil }
        let savedIndex = buffer.readerIndex
        guard let typeByte: UInt8 = buffer.readInteger(),
              let length: UInt32 = buffer.readInteger(endianness: .big),
              let type = AttachFrameType(rawValue: typeByte), length <= 16 * 1_024 * 1_024 else {
            throw AttachBrokerError.protocolError
        }
        guard buffer.readableBytes >= Int(length) else {
            buffer.moveReaderIndex(to: savedIndex)
            return nil
        }
        return (type, Data(buffer.readBytes(length: Int(length)) ?? []))
    }

    private func process(_ frame: (AttachFrameType, Data), context: ChannelHandlerContext) {
        switch frame.0 {
        case .hello:
            guard session == nil, let hello = try? JSONDecoder().decode(AttachHello.self, from: frame.1),
                  hello.version == AttachDescriptor.protocolVersion else {
                context.close(promise: nil); return
            }
            let clientChannel = context.channel
            let helloToken = hello.token
            Task { [broker, clientChannel] in
                do {
                    let claimedAttach = try await broker.claim(
                        token: helloToken,
                        size: TerminalSize(columns: max(1, hello.columns), rows: max(1, hello.rows))
                    )
                    guard clientChannel.isActive else {
                        await broker.detach(token: helloToken)
                        return
                    }
                    clientChannel.eventLoop.execute {
                        self.session = claimedAttach.session
                        self.token = helloToken
                        self.claimed = true
                        guard clientChannel.isActive else {
                            Task { await broker.detach(token: helloToken) }
                            return
                        }
                        Task { [clientChannel] in
                            for await event in claimedAttach.events {
                                clientChannel.eventLoop.execute { self.forward(event, channel: clientChannel) }
                            }
                        }
                    }
                } catch {
                    clientChannel.eventLoop.execute {
                        self.write(.status, Data("\r\n[Terminator: \(error.localizedDescription)]\r\n".utf8), channel: clientChannel)
                        clientChannel.close(promise: nil)
                    }
                }
            }
        case .input:
            guard let session else { return }
            Task { try? await session.write(frame.1) }
        case .resize:
            guard let session, let values = try? JSONDecoder().decode([Int].self, from: frame.1), values.count == 2 else { return }
            Task { try? await session.resize(to: .init(columns: max(1, values[0]), rows: max(1, values[1]))) }
        default: break
        }
    }

    private func forward(_ event: SSHSessionEvent, channel: Channel) {
        switch event {
        case .stdout(let data): write(.stdout, data, channel: channel)
        case .stderr(let data): write(.stderr, data, channel: channel)
        case .status(let message): write(.status, Data(message.utf8), channel: channel)
        case .exited:
            write(.exit, Data(), channel: channel)
            channel.close(promise: nil)
        }
    }

    private func write(_ type: AttachFrameType, _ payload: Data, context: ChannelHandlerContext) {
        write(type, payload, channel: context.channel)
    }

    private func write(_ type: AttachFrameType, _ payload: Data, channel: Channel) {
        var output = channel.allocator.buffer(capacity: payload.count + 5)
        output.writeInteger(type.rawValue)
        output.writeInteger(UInt32(payload.count), endianness: .big)
        output.writeBytes(payload)
        channel.writeAndFlush(output, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if claimed, let token {
            Task { await broker.detach(token: token) }
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
