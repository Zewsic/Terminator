import Foundation
import NIOCore
import NIOPosix
import TerminatorCore

public actor ConnectionServiceClient: ExternalTerminalConnecting {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var pending: [UUID: CheckedContinuation<ConnectionControlResponse, any Error>] = [:]
    private var phaseContinuations: [UUID: [UUID: AsyncStream<SSHConnectionPhase>.Continuation]] = [:]
    private var promptHandler: (@Sendable (ConnectionPromptEnvelope) async -> ConnectionPromptReply)?
    private var isConnecting = false
    private var connectionWaiters: [CheckedContinuation<Void, any Error>] = []
    private var reconnectTask: Task<Void, Never>?

    public init() {}

    deinit { try? group.syncShutdownGracefully() }

    public func setPromptHandler(
        _ handler: @escaping @Sendable (ConnectionPromptEnvelope) async -> ConnectionPromptReply
    ) {
        promptHandler = handler
    }

    public func installedApplications() async -> [TerminalApplication] {
        TerminalApplication.allCases
    }

    public func connect(host: HostProfile, terminal: TerminalApplication) async throws {
        try await connect(hostID: host.id, terminal: terminal)
    }

    public func connect(hostID: UUID, terminal: TerminalApplication = .terminal) async throws {
        let response = try await request(.connect(hostID: hostID, terminal: terminal))
        if case .failed(let message) = response { throw ConnectionServiceError.failed(message) }
    }

    public func makeConnectionCommand(host: HostProfile) async throws -> String {
        let response = try await request(.command(hostID: host.id))
        switch response {
        case .command(let command): return command
        case .failed(let message): throw ConnectionServiceError.failed(message)
        default: throw ConnectionServiceError.unavailable
        }
    }

    public func state(for hostID: UUID) async -> SSHConnectionPhase {
        let response = try? await request(.state(hostID: hostID))
        if case .phase(let phase) = response { return phase }
        return .disconnected
    }

    public func states(for hostID: UUID) async -> AsyncStream<SSHConnectionPhase> {
        let observerID = UUID()
        return AsyncStream { continuation in
            Task {
                self.addPhaseObserver(observerID, hostID: hostID, continuation: continuation)
                continuation.yield(await self.state(for: hostID))
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removePhaseObserver(observerID, hostID: hostID) }
            }
        }
    }

    public func disconnect(hostID: UUID) async {
        _ = try? await request(.disconnect(hostID: hostID))
    }

    public func listHosts() async throws -> [HostAccessSummary] {
        let response = try await request(.listHosts)
        switch response {
        case .hosts(let hosts): return hosts
        case .failed(let message): throw ConnectionServiceError.failed(message)
        default: throw ConnectionServiceError.unavailable
        }
    }

    public func connectHeadless(hostID: UUID) async throws -> UUID {
        let response = try await request(.connectHeadless(hostID: hostID))
        switch response {
        case .sessionID(let id): return id
        case .failed(let message): throw ConnectionServiceError.failed(message)
        default: throw ConnectionServiceError.unavailable
        }
    }

    public func listSessions() async throws -> [SessionAccessSummary] {
        let response = try await request(.listSessions)
        switch response {
        case .sessions(let sessions): return sessions
        case .failed(let message): throw ConnectionServiceError.failed(message)
        default: throw ConnectionServiceError.unavailable
        }
    }

    public func writeSession(id: UUID, text: String) async throws {
        let response = try await request(.sessionWrite(sessionID: id, text: text))
        if case .failed(let message) = response { throw ConnectionServiceError.failed(message) }
        if case .ok = response { return }
        throw ConnectionServiceError.unavailable
    }

    public func readSession(id: UUID, after: Int) async throws -> (text: String, next: Int) {
        let response = try await request(.sessionRead(sessionID: id, after: after))
        switch response {
        case .sessionOutput(let text, let next): return (text, next)
        case .failed(let message): throw ConnectionServiceError.failed(message)
        default: throw ConnectionServiceError.unavailable
        }
    }

    public func ensureConnected() async throws {
        if channel?.isActive == true { return }
        if isConnecting {
            return try await withCheckedThrowingContinuation { connectionWaiters.append($0) }
        }
        isConnecting = true
        let socketURL = ConnectionServicePaths.controlSocketURL
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(ConnectionServiceError.unavailable)
                }
                return channel.pipeline.addHandler(ControlClientHandler(client: self))
            }
        do {
            let connected = try await bootstrap.connect(unixDomainSocketPath: socketURL.path).get()
            channel = connected
            let response = try await send(.subscribe, over: connected)
            guard case .ok = response else { throw ConnectionServiceError.unavailable }
            finishConnecting(with: .success(()))
        } catch {
            channel = nil
            finishConnecting(with: .failure(ConnectionServiceError.unavailable))
            scheduleReconnectIfNeeded()
            throw ConnectionServiceError.unavailable
        }
    }

    fileprivate func receive(_ frame: ConnectionControlFrame) {
        switch frame {
        case .response(let id, let response):
            pending.removeValue(forKey: id)?.resume(returning: response)
        case .event(.phase(let hostID, let phase)):
            if let observers = phaseContinuations[hostID] {
                for continuation in observers.values { continuation.yield(phase) }
            }
        case .event(.prompt(let envelope)):
            Task { await self.answer(envelope) }
        case .request:
            break
        }
    }

    fileprivate func connectionDropped(_ droppedChannel: Channel) {
        guard channel.map(ObjectIdentifier.init) == ObjectIdentifier(droppedChannel) else { return }
        channel = nil
        let error = ConnectionServiceError.unavailable
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        for observers in phaseContinuations.values {
            for continuation in observers.values { continuation.yield(.disconnected) }
        }
        scheduleReconnectIfNeeded()
    }

    private func answer(_ envelope: ConnectionPromptEnvelope) async {
        let reply = await promptHandler?(envelope) ?? .cancelled
        _ = try? await request(.answer(promptID: envelope.id, reply: reply))
    }

    private func request(_ request: ConnectionControlRequest) async throws -> ConnectionControlResponse {
        try await ensureConnected()
        guard let channel else { throw ConnectionServiceError.unavailable }
        return try await send(request, over: channel)
    }

    private func send(
        _ request: ConnectionControlRequest,
        over channel: Channel
    ) async throws -> ConnectionControlResponse {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            guard let data = try? ConnectionControlCodec.line(from: .request(id: id, request)) else {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: ConnectionServiceError.unavailable)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                await self?.timeoutRequest(id)
            }
            let requestOwner = self
            channel.eventLoop.execute {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                let promise = channel.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenFailure { _ in
                    Task { await requestOwner.failRequest(id) }
                }
                channel.writeAndFlush(buffer, promise: promise)
            }
        }
    }

    private func timeoutRequest(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: ConnectionServiceError.unavailable)
    }

    private func failRequest(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: ConnectionServiceError.unavailable)
    }

    private func finishConnecting(with result: Result<Void, any Error>) {
        isConnecting = false
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters {
            switch result {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    private func scheduleReconnectIfNeeded() {
        guard !phaseContinuations.isEmpty, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            var delay = Duration.milliseconds(250)
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.ensureConnected()
                    await self.resynchronizeObservedHosts()
                    await self.finishReconnect()
                    return
                } catch {
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(5))
                }
            }
        }
    }

    private func resynchronizeObservedHosts() async {
        for hostID in phaseContinuations.keys {
            guard let response = try? await request(.state(hostID: hostID)),
                  case .phase(let phase) = response else { continue }
            for continuation in phaseContinuations[hostID]?.values ?? [:].values {
                continuation.yield(phase)
            }
        }
    }

    private func finishReconnect() {
        reconnectTask = nil
    }

    private func addPhaseObserver(
        _ observerID: UUID,
        hostID: UUID,
        continuation: AsyncStream<SSHConnectionPhase>.Continuation
    ) {
        phaseContinuations[hostID, default: [:]][observerID] = continuation
        scheduleReconnectIfNeeded()
    }

    private func removePhaseObserver(_ observerID: UUID, hostID: UUID) {
        phaseContinuations[hostID]?[observerID] = nil
        if phaseContinuations[hostID]?.isEmpty == true {
            phaseContinuations[hostID] = nil
        }
        if phaseContinuations.isEmpty {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }
}

private final class ControlClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let client: ConnectionServiceClient
    private var buffer = ByteBuffer()

    init(client: ConnectionServiceClient) { self.client = client }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let line = readLine() {
            guard let frame = try? ConnectionControlCodec.frame(from: line) else { continue }
            Task { await client.receive(frame) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let channel = context.channel
        Task { await client.connectionDropped(channel) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    private func readLine() -> Data? {
        guard let index = buffer.readableBytesView.firstIndex(of: 0x0A) else { return nil }
        let length = index - buffer.readableBytesView.startIndex
        let bytes = buffer.readBytes(length: length) ?? []
        buffer.moveReaderIndex(forwardBy: 1)
        return Data(bytes)
    }
}
