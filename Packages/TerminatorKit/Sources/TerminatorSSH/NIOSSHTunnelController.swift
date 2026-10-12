import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import TerminatorCore

extension NIOSSHConnectionCoordinator {
    public func setTunnelPhaseHandler(_ handler: @escaping @Sendable (UUID, SSHConnectionPhase) -> Void) {
        tunnelPhaseHandler = handler
    }

    func startForward(_ tunnel: TunnelProfile) async throws {
        let tunnel = try tunnel.validated()
        _ = try TunnelForwardPlan.make(tunnel)
        if desiredTunnels[tunnel.id] != nil { return }
        desiredTunnels[tunnel.id] = tunnel
        await desiredWork?.addTunnel(tunnel.id)
        do {
            try await openForward(tunnel)
            cancelTunnelRetry(tunnel.id)
        } catch {
            reportTunnel(tunnel.id, .failed(message: error.localizedDescription))
            scheduleTunnelRetry(tunnel.id)
        }
    }

    func stopForward(id: UUID) async {
        cancelTunnelRetry(id)
        desiredTunnels[id] = nil
        await teardownForward(id)
        await desiredWork?.removeTunnel(id)
        reportTunnel(id, .disconnected)
    }

    func suspendTunnels(touching hostID: UUID) async {
        let ids = runningTunnels.keys.filter { desiredTunnels[$0]?.usesPool(hostID) == true }
        for id in ids {
            await teardownForward(id)
            reportTunnel(id, .reconnecting(attempt: 1))
        }
    }

    func resumeTunnels(touching hostID: UUID) async {
        for (id, tunnel) in desiredTunnels where tunnel.usesPool(hostID) && runningTunnels[id] == nil {
            guard poolsReady(tunnel) else {
                scheduleTunnelRetry(id)
                continue
            }
            do {
                try await openForward(tunnel)
                cancelTunnelRetry(id)
            } catch {
                reportTunnel(id, .failed(message: error.localizedDescription))
                scheduleTunnelRetry(id)
            }
        }
    }

    func poolsReady(_ tunnel: TunnelProfile) -> Bool {
        let hostIDs = [tunnel.source.poolHostID, tunnel.destination.poolHostID].compactMap { $0 }
        return hostIDs.allSatisfy { retainedHosts.contains($0) && pools[$0]?.channel.isActive == true }
    }

    func scheduleTunnelRetry(_ id: UUID) {
        guard tunnelRetryTasks[id] == nil else { return }
        tunnelRetryTasks[id] = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                attempt += 1
                let seconds = min(30.0, pow(2.0, Double(min(attempt - 1, 5))))
                try? await Task.sleep(for: .seconds(seconds + Double.random(in: 0 ... 0.5)))
                if Task.isCancelled { return }
                guard let tunnel = await self.desiredTunnel(id) else {
                    await self.cancelTunnelRetry(id)
                    return
                }
                guard await self.poolsReady(tunnel) else { continue }
                if await self.tunnelIsRunning(id) {
                    await self.cancelTunnelRetry(id)
                    return
                }
                do {
                    try await self.openForward(tunnel)
                    await self.cancelTunnelRetry(id)
                    return
                } catch {
                    await self.reportTunnel(id, .failed(message: error.localizedDescription))
                }
            }
        }
    }

    func desiredTunnel(_ id: UUID) -> TunnelProfile? { desiredTunnels[id] }
    func tunnelIsRunning(_ id: UUID) -> Bool { runningTunnels[id] != nil }


    func cancelTunnelRetry(_ id: UUID) {
        tunnelRetryTasks[id]?.cancel()
        tunnelRetryTasks[id] = nil
    }

    func stopTunnels(touching hostID: UUID) async {
        let ids = desiredTunnels.filter { $0.value.usesPool(hostID) }.map(\.key)
        for id in ids { await stopForward(id: id) }
    }

    func openForward(_ tunnel: TunnelProfile) async throws {
        let plan = try TunnelForwardPlan.make(tunnel)
        let children = TunnelChannelSet()
        let meter = TunnelTrafficMeter()
        switch plan {
        case .listenLocally(let address, let port, let dial):
            let listener = try await bindLocal(address: address, port: port) { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(SSHTransportError.sessionUnavailable)
                }
                return self.acceptLocal(channel, dial: dial, children: children, meter: meter)
            }
            runningTunnels[tunnel.id] = RunningTunnel(listener: listener, remote: nil, children: children)
        case .listenRemotely(let listener, let address, let port, let dial):
            guard let hostID = listener.poolHostID else { throw SSHTransportError.sessionUnavailable }
            let key = TunnelForwardRouter.Key(hostID: hostID, host: address.lowercased(), port: port)
            forwardRouter.set(key) { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(SSHTransportError.sessionUnavailable)
                }
                return self.acceptForwarded(channel, dial: dial, children: children, meter: meter)
            }
            do {
                try await requestForward(hostID: hostID, host: address, port: port, cancel: false)
            } catch {
                forwardRouter.remove(key)
                throw error
            }
            runningTunnels[tunnel.id] = RunningTunnel(
                listener: nil,
                remote: RemoteListen(hostID: hostID, host: address, port: port),
                children: children
            )
        }
        tunnelMeters[tunnel.id] = meter
        reportTunnel(tunnel.id, .connected)
    }

    func teardownForward(_ id: UUID) async {
        tunnelMeters[id] = nil
        guard let running = runningTunnels.removeValue(forKey: id) else { return }
        if let remote = running.remote {
            let key = TunnelForwardRouter.Key(hostID: remote.hostID, host: remote.host.lowercased(), port: remote.port)
            forwardRouter.remove(key)
            try? await requestForward(hostID: remote.hostID, host: remote.host, port: remote.port, cancel: true)
        }
        running.children.closeAll()
        if let listener = running.listener, listener.isActive {
            try? await listener.close().get()
        }
    }

    func reportTunnel(_ id: UUID, _ phase: SSHConnectionPhase) {
        reportedTunnelPhases[id] = phase
        tunnelPhaseHandler?(id, phase)
    }

    func bindLocal(
        address: String,
        port: Int,
        child: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer(child)
        return try await bootstrap.bind(host: address, port: port).get()
    }
    nonisolated func acceptLocal(
        _ channel: Channel,
        dial: TunnelForwardPlan.Dial,
        children: TunnelChannelSet,
        meter: TunnelTrafficMeter
    ) -> EventLoopFuture<Void> {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        children.add(channel)
        Task {
            do {
                switch dial {
                case .socks(let through):
                    try await self.installSOCKS(on: channel, through: through, children: children, meter: meter)
                default:
                    try await self.completeDial(dial, peer: channel, children: children, meter: meter)
                }
                promise.succeed(())
            } catch {
                promise.fail(error)
                channel.close(promise: nil)
            }
        }
        return promise.futureResult
    }

    nonisolated func acceptForwarded(
        _ channel: Channel,
        dial: TunnelForwardPlan.Dial,
        children: TunnelChannelSet,
        meter: TunnelTrafficMeter
    ) -> EventLoopFuture<Void> {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        children.add(channel)
        Task {
            do {
                try await self.completeDial(dial, peer: channel, children: children, peerIsSSH: true, meter: meter)
                promise.succeed(())
            } catch {
                promise.fail(error)
                channel.close(promise: nil)
            }
        }
        return promise.futureResult
    }

    func completeDial(
        _ dial: TunnelForwardPlan.Dial,
        peer: Channel,
        children: TunnelChannelSet,
        peerIsSSH: Bool = false,
        meter: TunnelTrafficMeter
    ) async throws {
        switch dial {
        case .localAddress(let host, let port):
            let tcp = try await ClientBootstrap(group: group).connect(host: host, port: port).get()
            children.add(tcp)
            if peerIsSSH {
                try await glue(ssh: peer, tcp: tcp, clientIsSSH: true, meter: meter)
            } else {
                try await gluePlain(peer, tcp, meter: meter)
            }
        case .through(let endpoint, let host, let port):
            let ssh = try await openDirect(
                endpoint: endpoint, host: host, port: port, origin: peer.remoteAddress
            )
            children.add(ssh)
            if peerIsSSH {
                try await glueSSH(peer, ssh, meter: meter)
            } else {
                try await glue(ssh: ssh, tcp: peer, clientIsSSH: false, meter: meter)
            }
        case .socks(let through):
            try await installSOCKS(on: peer, through: through, children: children, meter: meter)
        }
    }

    func installSOCKS(
        on channel: Channel,
        through endpoint: TunnelEndpoint,
        children: TunnelChannelSet,
        meter: TunnelTrafficMeter
    ) async throws {
        let handler = SOCKS5ServerHandler { [weak self] handler, targetHost, targetPort in
            guard let self else { throw SSHTransportError.sessionUnavailable }
            let ssh = try await self.openDirect(
                endpoint: endpoint, host: targetHost, port: targetPort, origin: channel.remoteAddress
            )
            children.add(ssh)
            let leftover = handler.drain()
            try await channel.eventLoop.submit {
                channel.pipeline.syncOperations.removeHandler(handler)
            }.get()
            try await self.glue(ssh: ssh, tcp: channel, initialTCP: leftover, clientIsSSH: false, meter: meter)
        }
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(handler)
        }.get()
    }

    func openDirect(
        endpoint: TunnelEndpoint,
        host: String,
        port: Int,
        origin: SocketAddress?
    ) async throws -> Channel {
        guard let hostID = endpoint.poolHostID, let pool = pools[hostID], pool.channel.isActive else {
            throw SSHTransportError.sessionUnavailable
        }
        let parent = pool.channel
        let originator = try origin ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)
        return try await withCheckedThrowingContinuation { continuation in
            parent.eventLoop.execute {
                do {
                    let handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    let promise = parent.eventLoop.makePromise(of: Channel.self)
                    let kind = SSHChannelType.directTCPIP(
                        .init(targetHost: host, targetPort: port, originatorAddress: originator)
                    )
                    handler.createChannel(promise, channelType: kind) { child, type in
                        guard case .directTCPIP = type else {
                            return child.eventLoop.makeFailedFuture(SSHTransportError.sessionUnavailable)
                        }
                        return child.eventLoop.makeSucceededFuture(())
                    }
                    promise.futureResult.whenComplete { result in
                        continuation.resume(with: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func requestForward(hostID: UUID, host: String, port: Int, cancel: Bool) async throws {
        guard let pool = pools[hostID], pool.channel.isActive else { throw SSHTransportError.sessionUnavailable }
        let parent = pool.channel
        let request: GlobalRequest.TCPForwardingRequest = cancel
            ? .cancel(host: host, port: port)
            : .listen(host: host, port: port)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            parent.eventLoop.execute {
                do {
                    let handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    let promise = parent.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                    handler.sendTCPForwardingRequest(request, promise: promise)
                    promise.futureResult.whenComplete { result in
                        continuation.resume(with: result.map { _ in () })
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func glue(
        ssh: Channel,
        tcp: Channel,
        initialTCP: ByteBuffer? = nil,
        clientIsSSH: Bool,
        meter: TunnelTrafficMeter
    ) async throws {
        let (sshSide, tcpSide) = TunnelGlue.matchedPair(meter: meter, firstIsInbound: clientIsSSH)
        try await ssh.eventLoop.submit {
            try ssh.pipeline.syncOperations.addHandler(SSHByteAdapter())
            try ssh.pipeline.syncOperations.addHandler(sshSide)
        }.get()
        try await tcp.eventLoop.submit {
            try tcp.pipeline.syncOperations.addHandler(tcpSide)
            if let initialTCP, initialTCP.readableBytes > 0 {
                tcp.pipeline.fireChannelRead(initialTCP)
                tcp.pipeline.fireChannelReadComplete()
            }
        }.get()
    }

    func glueSSH(_ left: Channel, _ right: Channel, meter: TunnelTrafficMeter) async throws {
        let (leftSide, rightSide) = TunnelGlue.matchedPair(meter: meter, firstIsInbound: true)
        try await left.eventLoop.submit {
            try left.pipeline.syncOperations.addHandler(SSHByteAdapter())
            try left.pipeline.syncOperations.addHandler(leftSide)
        }.get()
        try await right.eventLoop.submit {
            try right.pipeline.syncOperations.addHandler(SSHByteAdapter())
            try right.pipeline.syncOperations.addHandler(rightSide)
        }.get()
    }

    func gluePlain(_ left: Channel, _ right: Channel, meter: TunnelTrafficMeter) async throws {
        let (leftSide, rightSide) = TunnelGlue.matchedPair(meter: meter, firstIsInbound: true)
        try await left.eventLoop.submit {
            try left.pipeline.syncOperations.addHandler(leftSide)
        }.get()
        try await right.eventLoop.submit {
            try right.pipeline.syncOperations.addHandler(rightSide)
        }.get()
    }
}

struct RunningTunnel {
    var listener: Channel?
    var remote: RemoteListen?
    var children: TunnelChannelSet
}

struct RemoteListen {
    var hostID: UUID
    var host: String
    var port: Int
}

final class TunnelChannelSet: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]

    func add(_ channel: Channel) {
        lock.lock()
        channels[ObjectIdentifier(channel)] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.remove(channel)
        }
    }

    func closeAll() {
        lock.lock()
        let open = Array(channels.values)
        channels.removeAll()
        lock.unlock()
        for channel in open where channel.isActive {
            channel.close(promise: nil)
        }
    }

    private func remove(_ channel: Channel) {
        lock.lock()
        channels[ObjectIdentifier(channel)] = nil
        lock.unlock()
    }
}

final class TunnelForwardRouter: @unchecked Sendable {
    struct Key: Hashable {
        var hostID: UUID
        var host: String
        var port: Int
    }

    private let lock = NSLock()
    private var handlers: [Key: @Sendable (Channel) -> EventLoopFuture<Void>] = [:]

    func set(_ key: Key, _ handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) {
        lock.lock()
        handlers[key] = handler
        lock.unlock()
    }

    func remove(_ key: Key) {
        lock.lock()
        handlers[key] = nil
        lock.unlock()
    }

    func accept(hostID: UUID, channel: Channel, type: SSHChannelType) -> EventLoopFuture<Void> {
        guard case .forwardedTCPIP(let info) = type else {
            return channel.eventLoop.makeFailedFuture(SSHTransportError.sessionUnavailable)
        }
        let key = Key(hostID: hostID, host: info.listeningHost.lowercased(), port: info.listeningPort)
        lock.lock()
        let handler = handlers[key]
        lock.unlock()
        guard let handler else {
            return channel.close().flatMap {
                channel.eventLoop.makeFailedFuture(SSHTransportError.sessionUnavailable)
            }
        }
        return handler(channel)
    }
}

final class TunnelTrafficMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var received: UInt64 = 0
    private var sent: UInt64 = 0
    let startedAt = Date()

    func add(received extraIn: Int = 0, sent extraOut: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        if extraIn > 0 { received += UInt64(extraIn) }
        if extraOut > 0 { sent += UInt64(extraOut) }
    }

    func snapshot(id: UUID) -> TunnelTrafficSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return TunnelTrafficSnapshot(id: id, received: received, sent: sent, startedAt: startedAt)
    }
}

final class TunnelGlue: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: TunnelGlue?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    private let meter: TunnelTrafficMeter?
    private let inbound: Bool

    init(meter: TunnelTrafficMeter?, inbound: Bool) {
        self.meter = meter
        self.inbound = inbound
    }

    static func matchedPair(meter: TunnelTrafficMeter?, firstIsInbound: Bool) -> (TunnelGlue, TunnelGlue) {
        let first = TunnelGlue(meter: meter, inbound: firstIsInbound)
        let second = TunnelGlue(meter: meter, inbound: !firstIsInbound)
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if inbound {
            meter?.add(received: buffer.readableBytes)
        } else {
            meter?.add(sent: buffer.readableBytes)
        }
        partner?.partnerWrite(buffer)
    }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerClose() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerClose() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event { partner?.partnerWriteEOF() }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if partner?.isWritable == true { context.read() } else { pendingRead = true }
    }

    private var isWritable: Bool { context?.channel.isWritable ?? false }
    private func partnerWrite(_ data: ByteBuffer) {
        guard let context else { return }
        context.write(wrapOutboundOut(data), promise: nil)
    }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerClose() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
}

final class SSHByteAdapter: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(SSHTransportError.sessionUnavailable)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

final class SOCKS5ServerHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer = ByteBuffer()
    private var greeted = false
    private var forwarding = false
    private let connect: @Sendable (SOCKS5ServerHandler, String, Int) async throws -> Void

    init(connect: @escaping @Sendable (SOCKS5ServerHandler, String, Int) async throws -> Void) {
        self.connect = connect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if forwarding {
            buffer.writeBuffer(&incoming)
            return
        }
        buffer.writeBuffer(&incoming)
        if !greeted {
            guard buffer.readableBytes >= 2, buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 5 else {
                if buffer.readableBytes >= 2 { context.close(promise: nil) }
                return
            }
            let methods = Int(buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) ?? 0)
            guard buffer.readableBytes >= 2 + methods else { return }
            buffer.moveReaderIndex(forwardBy: 2 + methods)
            greeted = true
            var reply = context.channel.allocator.buffer(capacity: 2)
            reply.writeInteger(UInt8(5))
            reply.writeInteger(UInt8(0))
            context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
        }
        guard let request = SOCKS5RequestParser.takeRequest(&buffer) else { return }
        forwarding = true
        let host = request.host
        let port = request.port
        var reply = context.channel.allocator.buffer(capacity: 10)
        reply.writeBytes([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
        let channel = context.channel
        Task {
            do {
                try await self.connect(self, host, port)
            } catch {
                channel.eventLoop.execute { channel.close(promise: nil) }
            }
        }
    }

    func drain() -> ByteBuffer {
        let pending = buffer
        buffer.clear()
        return pending
    }
}

enum SOCKS5RequestParser {
    struct Request: Equatable { var host: String; var port: Int }

    static func takeRequest(_ buffer: inout ByteBuffer) -> Request? {
        guard buffer.readableBytes >= 4,
              buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 5,
              buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) == 1 else { return nil }
        let kind = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self) ?? 0
        var index = buffer.readerIndex + 4
        let host: String
        switch kind {
        case 1:
            guard let bytes = buffer.getBytes(at: index, length: 4), bytes.count == 4 else { return nil }
            host = bytes.map(String.init).joined(separator: ".")
            index += 4
        case 3:
            guard let length = buffer.getInteger(at: index, as: UInt8.self) else { return nil }
            index += 1
            guard let bytes = buffer.getBytes(at: index, length: Int(length)),
                  let name = String(bytes: bytes, encoding: .utf8) else { return nil }
            host = name
            index += Int(length)
        case 4:
            guard let bytes = buffer.getBytes(at: index, length: 16), bytes.count == 16 else { return nil }
            var parts: [String] = []
            for offset in stride(from: 0, to: 16, by: 2) {
                parts.append(String(format: "%02x%02x", bytes[offset], bytes[offset + 1]))
            }
            host = parts.joined(separator: ":")
            index += 16
        default:
            return nil
        }
        guard let port: UInt16 = buffer.getInteger(at: index) else { return nil }
        buffer.moveReaderIndex(to: index + 2)
        return Request(host: host, port: Int(port))
    }
}
