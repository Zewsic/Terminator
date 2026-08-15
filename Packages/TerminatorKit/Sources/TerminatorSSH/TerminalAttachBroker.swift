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
    private struct Pending: Sendable {
        var session: SSHSessionHandle
        var expiresAt: Date
    }

    private let coordinator: any SSHConnectionCoordinating
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let directoryURL: URL
    private let socketURL: URL
    private var serverChannel: Channel?
    private var pending: [String: Pending] = [:]

    public init(coordinator: any SSHConnectionCoordinating, directoryURL: URL) {
        self.coordinator = coordinator
        self.directoryURL = directoryURL
        self.socketURL = directoryURL.appending(path: "attach.sock")
    }

    deinit { try? group.syncShutdownGracefully() }

    public func createDescriptor(host: HostProfile, terminal: TerminalApplication) async throws -> AttachDescriptor {
        try await startIfNeeded()
        await removeExpired()
        // Opening a child SSH session is the authentication barrier. Do not
        // launch an external terminal until the server has accepted one of the
        // configured authentication methods and the PTY channel is usable.
        let session = try await coordinator.openSession(
            host: host, terminal: terminal, size: .init(columns: 80, rows: 24)
        )
        let token = Self.token()
        let expiresAt = Date.now.addingTimeInterval(600)
        pending[token] = Pending(session: session, expiresAt: expiresAt)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            await self?.expire(token: token)
        }
        return AttachDescriptor(
            sessionID: session.id, socketPath: socketURL.path, token: token, expiresAt: expiresAt
        )
    }

    public func cancel(_ descriptor: AttachDescriptor) async {
        guard let value = pending.removeValue(forKey: descriptor.token) else { return }
        await value.session.close()
    }

    public func command(for descriptor: AttachDescriptor, helperURL: URL) -> String {
        [helperURL.path, "--socket", descriptor.socketPath, "--token", descriptor.token]
            .map(Self.shellQuote)
            .joined(separator: " ")
    }

    fileprivate func claim(token: String, size: TerminalSize) async throws -> SSHSessionHandle {
        await removeExpired()
        guard let value = pending.removeValue(forKey: token), value.expiresAt > .now else {
            throw AttachBrokerError.expiredOrInvalidToken
        }
        try await value.session.resize(to: size)
        return value.session
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
        let expired = pending.filter { $0.value.expiresAt <= now }
        pending = pending.filter { $0.value.expiresAt > now }
        for value in expired.values { await value.session.close() }
    }

    private func expire(token: String) async {
        guard let value = pending[token], value.expiresAt <= .now else { return }
        pending[token] = nil
        await value.session.close()
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
            Task { [broker, clientChannel] in
                do {
                    let handle = try await broker.claim(
                        token: hello.token,
                        size: TerminalSize(columns: max(1, hello.columns), rows: max(1, hello.rows))
                    )
                    clientChannel.eventLoop.execute {
                        self.session = handle
                        Task { [clientChannel] in
                            for await event in handle.events {
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
        if let session { Task { await session.close() } }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
