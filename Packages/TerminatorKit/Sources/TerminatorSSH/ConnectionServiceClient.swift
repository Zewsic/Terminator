import Foundation
import NIOCore
import NIOPosix
import TerminatorCore

public actor ConnectionServiceClient: ExternalTerminalConnecting, SSHTunnelControlling {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var pending: [UUID: CheckedContinuation<ConnectionControlResponse, any Error>] = [:]
    private var phaseContinuations: [UUID: [UUID: AsyncStream<SSHConnectionPhase>.Continuation]] = [:]
    private var tunnelContinuations: [UUID: AsyncStream<TunnelPhaseEvent>.Continuation] = [:]
    private var dockerContinuations: [UUID: AsyncStream<DockerInventorySnapshot>.Continuation] = [:]
    private var statusContinuations: [UUID: AsyncStream<HostStatusSnapshot>.Continuation] = [:]
    private var trafficContinuations: [UUID: AsyncStream<TunnelTrafficSnapshot>.Continuation] = [:]
    private var latestDocker = DockerInventorySnapshot()
    private var latestHostPhases: [UUID: SSHConnectionPhase] = [:]
    private var latestTunnelPhases: [UUID: SSHConnectionPhase] = [:]
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

    public func connect(host: HostProfile, terminal: TerminalApplication) async throws -> DetectedHostOS? {
        try await connect(hostID: host.id, terminal: terminal)
    }

    public func connect(hostID: UUID, terminal: TerminalApplication = .terminal) async throws -> DetectedHostOS? {
        let response = try await request(.connect(hostID: hostID, terminal: terminal))
        switch response {
        case .ok: return nil
        case .connected(let os): return os
        case .failed(let message): throw ConnectionServiceError.failed(message)
        default: throw ConnectionServiceError.unavailable
        }
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

    public func startTunnel(_ tunnel: TunnelProfile) async throws {
        let response = try await request(.startTunnel(tunnel))
        if case .failed(let message) = response { throw ConnectionServiceError.failed(message) }
        guard case .ok = response else { throw ConnectionServiceError.unavailable }
    }

    public func stopTunnel(id: UUID) async {
        _ = try? await request(.stopTunnel(id))
    }

    public func tunnelPhases() async -> AsyncStream<TunnelPhaseEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task {
                await self.addTunnelObserver(id, continuation: continuation)
                try? await self.ensureConnected()
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTunnelObserver(id) }
            }
        }
    }

    public func dockerInventory() async -> AsyncStream<DockerInventorySnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            Task {
                await self.addDockerObserver(id, continuation: continuation)
                try? await self.ensureConnected()
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeDockerObserver(id) }
            }
        }
    }

    public func prepare(hostID: UUID) async throws {
        let response = try await request(.prepare(hostID: hostID))
        if case .failed(let message) = response { throw ConnectionServiceError.failed(message) }
        guard case .ok = response else { throw ConnectionServiceError.unavailable }
    }

    public func exec(host: HostProfile, command: String) async throws -> SSHExecResult {
        let timeout: Duration = command.contains("TERMINATOR_HELPER_") ? .seconds(300) : .seconds(30)
        let response = try await request(.exec(hostID: host.id, command: command), timeout: timeout)
        switch response {
        case .exec(let stdout, let stderr, let exitCode):
            return SSHExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
        case .failed(let message):
            throw ConnectionServiceError.failed(message)
        default:
            throw ConnectionServiceError.unavailable
        }
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
            latestHostPhases[hostID] = phase
            if let observers = phaseContinuations[hostID] {
                for continuation in observers.values { continuation.yield(phase) }
            }
        case .event(.prompt(let envelope)):
            Task { await self.answer(envelope) }
        case .event(.tunnelPhase(let event)):
            latestTunnelPhases[event.id] = event.phase
            for continuation in tunnelContinuations.values { continuation.yield(event) }
        case .event(.dockerInventory(let snapshot)):
            latestDocker = snapshot
            for continuation in dockerContinuations.values { continuation.yield(snapshot) }
        case .event(.hostStatus(let snapshot)):
            for continuation in statusContinuations.values { continuation.yield(snapshot) }
        case .event(.tunnelTraffic(let snapshot)):
            for continuation in trafficContinuations.values { continuation.yield(snapshot) }
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

    private func request(
        _ request: ConnectionControlRequest,
        timeout: Duration = .seconds(30)
    ) async throws -> ConnectionControlResponse {
        try await ensureConnected()
        guard let channel else { throw ConnectionServiceError.unavailable }
        return try await send(request, over: channel, timeout: timeout)
    }

    private func send(
        _ request: ConnectionControlRequest,
        over channel: Channel,
        timeout: Duration = .seconds(30)
    ) async throws -> ConnectionControlResponse {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            guard let data = try? ConnectionControlCodec.line(from: .request(id: id, request)) else {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: ConnectionServiceError.unavailable)
                return
            }
            let seconds = Double(timeout.components.seconds)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
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
        guard hasObservers, reconnectTask == nil else { return }
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

    private func addTunnelObserver(_ id: UUID, continuation: AsyncStream<TunnelPhaseEvent>.Continuation) {
        tunnelContinuations[id] = continuation
        for (tunnelID, phase) in latestTunnelPhases {
            continuation.yield(TunnelPhaseEvent(id: tunnelID, phase: phase))
        }
    }

    private func removeTunnelObserver(_ id: UUID) {
        tunnelContinuations[id] = nil
    }

    private func addPhaseObserver(
        _ observerID: UUID,
        hostID: UUID,
        continuation: AsyncStream<SSHConnectionPhase>.Continuation
    ) {
        phaseContinuations[hostID, default: [:]][observerID] = continuation
        if let phase = latestHostPhases[hostID] {
            continuation.yield(phase)
        }
        scheduleReconnectIfNeeded()
    }

    private func removePhaseObserver(_ observerID: UUID, hostID: UUID) {
        phaseContinuations[hostID]?[observerID] = nil
        if phaseContinuations[hostID]?.isEmpty == true {
            phaseContinuations[hostID] = nil
        }
        if !hasObservers {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    private var hasObservers: Bool {
        !phaseContinuations.isEmpty
            || !dockerContinuations.isEmpty
            || !tunnelContinuations.isEmpty
            || !statusContinuations.isEmpty
            || !trafficContinuations.isEmpty
    }

    private func addDockerObserver(
        _ id: UUID,
        continuation: AsyncStream<DockerInventorySnapshot>.Continuation
    ) {
        dockerContinuations[id] = continuation
        continuation.yield(latestDocker)
        scheduleReconnectIfNeeded()
    }

    private func removeDockerObserver(_ id: UUID) {
        dockerContinuations[id] = nil
        if !hasObservers {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    public func hostStatuses() async -> AsyncStream<HostStatusSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            Task {
                await self.addStatusObserver(id, continuation: continuation)
                try? await self.ensureConnected()
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStatusObserver(id) }
            }
        }
    }

    public func tunnelTraffic() async -> AsyncStream<TunnelTrafficSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            Task {
                await self.addTrafficObserver(id, continuation: continuation)
                try? await self.ensureConnected()
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTrafficObserver(id) }
            }
        }
    }

    public func controlDocker(
        endpoint: DockerEndpoint,
        containerID: String,
        action: DockerControlAction
    ) async throws -> String {
        let response = try await request(
            .docker(endpoint: endpoint, containerID: containerID, action: action)
        )
        switch response {
        case .exec(let stdout, let stderr, let exitCode):
            guard exitCode == 0 || action == .logs || action == .stats else {
                throw ConnectionServiceError.failed(stderr.isEmpty ? stdout : stderr)
            }
            return stdout
        case .failed(let message): throw ConnectionServiceError.failed(message)
        default: throw ConnectionServiceError.unavailable
        }
    }

    public func openContainerShell(endpoint: DockerEndpoint, containerID: String) async throws {
        let response = try await request(
            .containerShell(endpoint: endpoint, containerID: containerID)
        )
        switch response {
        case .ok: return
        case .failed(let message): throw ConnectionServiceError.failed(message)
        default: throw ConnectionServiceError.unavailable
        }
    }

    private func addStatusObserver(
        _ id: UUID,
        continuation: AsyncStream<HostStatusSnapshot>.Continuation
    ) {
        statusContinuations[id] = continuation
        scheduleReconnectIfNeeded()
    }

    private func removeStatusObserver(_ id: UUID) {
        statusContinuations[id] = nil
    }

    private func addTrafficObserver(
        _ id: UUID,
        continuation: AsyncStream<TunnelTrafficSnapshot>.Continuation
    ) {
        trafficContinuations[id] = continuation
        scheduleReconnectIfNeeded()
    }

    private func removeTrafficObserver(_ id: UUID) {
        trafficContinuations[id] = nil
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
