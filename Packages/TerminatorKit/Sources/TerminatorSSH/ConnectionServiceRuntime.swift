import Darwin
import Foundation
import NIOCore
import NIOPosix
import TerminatorCore

public actor ConnectionServiceRuntime {
    private let coordinator: NIOSSHConnectionCoordinator
    private let broker: TerminalAttachBroker
    private let hostRepository: any HostRepository
    private let prompting: ConnectionServicePrompter
    private let terminalLauncher: any ConnectionTerminalLaunching
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var server: Channel?
    private var serviceLockFD: Int32 = -1
    private var clients: [ObjectIdentifier: ControlClient] = [:]
    private var promptWaiters: [UUID: CheckedContinuation<ConnectionPromptReply, any Error>] = [:]
    private var publishing: Set<UUID> = []
    private var headless: [UUID: HeadlessSession] = [:]

    public init(
        coordinator: NIOSSHConnectionCoordinator,
        broker: TerminalAttachBroker,
        hostRepository: any HostRepository,
        prompting: ConnectionServicePrompter,
        terminalLauncher: any ConnectionTerminalLaunching
    ) {
        self.coordinator = coordinator
        self.broker = broker
        self.hostRepository = hostRepository
        self.prompting = prompting
        self.terminalLauncher = terminalLauncher
    }

    deinit {
        if serviceLockFD >= 0 {
            _ = Darwin.lockf(serviceLockFD, F_ULOCK, 0)
            Darwin.close(serviceLockFD)
        }
        try? group.syncShutdownGracefully()
    }

    public func start() async throws {
        try FileManager.default.createDirectory(
            at: ConnectionServicePaths.applicationSupport, withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: ConnectionServicePaths.applicationSupport.path
        )
        try acquireServiceLock()
        let socketURL = ConnectionServicePaths.controlSocketURL
        try? FileManager.default.removeItem(at: socketURL)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(ConnectionServiceError.unavailable)
                }
                return channel.pipeline.addHandler(ControlServerHandler(runtime: self))
            }
        server = try await bootstrap.bind(unixDomainSocketPath: socketURL.path).get()
        _ = Darwin.chmod(socketURL.path, 0o600)
    }

    public func waitUntilStopped() async throws {
        guard let server else { throw ConnectionServiceError.unavailable }
        try await server.closeFuture.get()
    }

    private func acquireServiceLock() throws {
        guard serviceLockFD < 0 else { return }
        let fd = Darwin.open(ConnectionServicePaths.serviceLockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ConnectionServiceError.unavailable }
        guard Darwin.lockf(fd, F_TLOCK, 0) == 0 else {
            Darwin.close(fd)
            throw ConnectionServiceError.unavailable
        }
        serviceLockFD = fd
    }

    fileprivate func register(_ channel: Channel) {
        clients[ObjectIdentifier(channel)] = ControlClient(channel: channel)
    }

    fileprivate func unregister(_ channel: Channel) {
        clients[ObjectIdentifier(channel)] = nil
    }

    fileprivate func handle(_ frame: ConnectionControlFrame, from channel: Channel) async {
        guard case .request(let id, let request) = frame else { return }
        switch request {
        case .subscribe:
            clients[ObjectIdentifier(channel)]?.subscribed = true
            write(.response(id: id, .ok), to: channel)
        case .connect(let hostID, let terminal):
            await prompting.bind(hostID: hostID)
            do {
                let detectedOS = try await connect(hostID: hostID, terminal: terminal)
                write(.response(id: id, .connected(detectedOS: detectedOS)), to: channel)
            } catch {
                write(.response(id: id, .failed(error.localizedDescription)), to: channel)
            }
        case .command(let hostID):
            await prompting.bind(hostID: hostID)
            do {
                write(.response(id: id, .command(try await makeCommand(hostID: hostID))), to: channel)
            } catch {
                write(.response(id: id, .failed(error.localizedDescription)), to: channel)
            }
        case .disconnect(let hostID):
            await coordinator.disconnect(hostID: hostID)
            write(.response(id: id, .ok), to: channel)
            broadcast(.phase(hostID: hostID, .disconnected))
        case .state(let hostID):
            write(.response(id: id, .phase(await coordinator.state(for: hostID))), to: channel)
        case .answer(let promptID, let reply):
            promptWaiters.removeValue(forKey: promptID)?.resume(returning: reply)
            write(.response(id: id, .ok), to: channel)
        case .listHosts:
            do {
                try requireMCP()
                write(.response(id: id, .hosts(try await listedHosts())), to: channel)
            } catch {
                write(.response(id: id, .failed(error.localizedDescription)), to: channel)
            }
        case .connectHeadless(let hostID):
            await prompting.bind(hostID: hostID)
            do {
                try requireMCP()
                write(.response(id: id, .sessionID(try await connectHeadless(hostID: hostID))), to: channel)
            } catch {
                write(.response(id: id, .failed(error.localizedDescription)), to: channel)
            }
        case .listSessions:
            do {
                try requireMCP()
                write(.response(id: id, .sessions(await listedSessions())), to: channel)
            } catch {
                write(.response(id: id, .failed(error.localizedDescription)), to: channel)
            }
        case .sessionWrite(let sessionID, let text):
            do {
                try requireMCP()
                try await coordinator.writeToSession(Data(text.utf8), id: sessionID)
                write(.response(id: id, .ok), to: channel)
            } catch {
                write(.response(id: id, .failed(error.localizedDescription)), to: channel)
            }
        case .sessionRead(let sessionID, let after):
            do {
                try requireMCP()
                let snapshot = headless[sessionID]?.output ?? ""
                let start = min(max(after, 0), snapshot.count)
                let text = String(snapshot.dropFirst(start))
                write(.response(id: id, .sessionOutput(text: text, next: snapshot.count)), to: channel)
            } catch {
                write(.response(id: id, .failed(error.localizedDescription)), to: channel)
            }
        case .exec(let hostID, let command):
            do {
                let result = try await exec(hostID: hostID, command: command)
                write(
                    .response(id: id, .exec(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)),
                    to: channel
                )
            } catch {
                write(.response(id: id, .failed(error.localizedDescription)), to: channel)
            }
        case .startTunnel(let tunnel):
            do {
                try await startTunnel(tunnel)
                write(.response(id: id, .ok), to: channel)
            } catch {
                write(.response(id: id, .failed(error.localizedDescription)), to: channel)
            }
        case .stopTunnel(let tunnelID):
            await coordinator.stopForward(id: tunnelID)
            write(.response(id: id, .ok), to: channel)
        }
    }

    public func publishTunnelPhase(id: UUID, phase: SSHConnectionPhase) {
        broadcast(.tunnelPhase(TunnelPhaseEvent(id: id, phase: phase)))
    }

    private func startTunnel(_ tunnel: TunnelProfile) async throws {
        let tunnel = try tunnel.validated()
        try await prepareTunnelEndpoint(tunnel.source)
        try await prepareTunnelEndpoint(tunnel.destination)
        try await coordinator.startForward(tunnel)
    }

    private func prepareTunnelEndpoint(_ endpoint: TunnelEndpoint) async throws {
        switch endpoint {
        case .thisMac:
            return
        case .saved(let id):
            guard let host = try await hostRepository.host(id: id), !host.isDeleted else {
                throw ConnectionServiceError.hostNotFound
            }
            await prompting.bind(hostID: id)
            if publishing.insert(id).inserted {
                Task { await publishStates(hostID: id) }
            }
            try await coordinator.prepare(host: host, prompting: prompting)
        case .manual(let id, let hostname, let port):
            let host = HostProfile(
                id: id,
                displayName: hostname,
                hostname: hostname,
                port: port,
                authentication: .manual(username: "", authenticationMethods: [])
            )
            await prompting.bind(hostID: id)
            try await coordinator.prepare(host: host, prompting: prompting)
        }
    }

    public func revealInterface() async {
        await terminalLauncher.revealTerminator()
    }

    public func request(_ envelope: ConnectionPromptEnvelope) async throws -> ConnectionPromptReply {
        await terminalLauncher.revealTerminator()
        await waitForSubscriber()
        return try await withCheckedThrowingContinuation { continuation in
            promptWaiters[envelope.id] = continuation
            broadcast(.prompt(envelope))
            Task {
                try? await Task.sleep(for: .seconds(300))
                if let waiter = self.takeWaiter(envelope.id) {
                    waiter.resume(throwing: ConnectionServiceError.promptTimedOut)
                }
            }
        }
    }

    private func takeWaiter(_ id: UUID) -> CheckedContinuation<ConnectionPromptReply, any Error>? {
        promptWaiters.removeValue(forKey: id)
    }

    private func connect(hostID: UUID, terminal: TerminalApplication) async throws -> DetectedHostOS? {
        guard let host = try await hostRepository.host(id: hostID), !host.isDeleted else {
            throw ConnectionServiceError.hostNotFound
        }
        if publishing.insert(hostID).inserted {
            Task { await publishStates(hostID: hostID) }
        }
        try await coordinator.prepare(host: host, prompting: prompting)
        let detectedOS = await probeOperatingSystem(host)
        let descriptor = try await broker.createDescriptor(host: host, terminal: terminal)
        do {
            let helper = try terminalLauncher.attachHelperURL()
            let command = await broker.command(for: descriptor, helperURL: helper)
            try await terminalLauncher.launch(terminal: terminal, command: command, descriptor: descriptor)
            return detectedOS
        } catch {
            await broker.cancel(descriptor)
            throw error
        }
    }

    private func requireMCP() throws {
        guard AccessPreferencesStore.load().mcpEnabled else { throw ConnectionServiceError.mcpDisabled }
    }

    private func listedHosts() async throws -> [HostAccessSummary] {
        let hosts = try await hostRepository.listHosts(includeDeleted: false)
        var result: [HostAccessSummary] = []
        for host in hosts {
            result.append(
                HostAccessSummary(
                    id: host.id,
                    name: host.displayName,
                    hostname: host.hostname,
                    port: host.port,
                    phase: await coordinator.state(for: host.id)
                )
            )
        }
        return result
    }

    private func listedSessions() async -> [SessionAccessSummary] {
        let names = Dictionary(
            uniqueKeysWithValues: ((try? await hostRepository.listHosts(includeDeleted: true)) ?? [])
                .map { ($0.id, $0.displayName) }
        )
        return await coordinator.listedSessions().map { session in
            SessionAccessSummary(
                id: session.id,
                hostID: session.hostID,
                hostName: names[session.hostID] ?? session.hostID.uuidString,
                kind: headless[session.id] == nil ? "terminal" : "headless"
            )
        }
    }

    private func probeOperatingSystem(_ host: HostProfile) async -> DetectedHostOS? {
        func log(_ message: String) {
            let url = ConnectionServicePaths.applicationSupport.appending(path: "os-probe.log")
            let line = "\(ISO8601DateFormatter().string(from: .now)) \(host.displayName): \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }

        if host.detectedOS != nil {
            log("skip existing \(host.detectedOS?.tag ?? "")")
            return host.detectedOS
        }
        do {
            let posix = try await coordinator.exec(host: host, command: HostOSProbe.posixCommand)
            log("posix exit=\(posix.exitCode) stdout=\(posix.stdout.prefix(400)) stderr=\(posix.stderr.prefix(200))")
            if let detected = HostOSProbe.parse(posix.stdout + "\n" + posix.stderr) {
                log("parsed \(detected.tag)")
                return detected
            }
            let windows = try await coordinator.exec(host: host, command: HostOSProbe.windowsCommand)
            log("windows exit=\(windows.exitCode) stdout=\(windows.stdout.prefix(400)) stderr=\(windows.stderr.prefix(200))")
            if let detected = HostOSProbe.parse(windows.stdout + "\n" + windows.stderr) {
                log("parsed \(detected.tag)")
                return detected
            }
            log("parse failed")
            return nil
        } catch {
            log("error \(error.localizedDescription)")
            return nil
        }
    }

    private func exec(hostID: UUID, command: String) async throws -> SSHExecResult {
        guard let host = try await hostRepository.host(id: hostID), !host.isDeleted else {
            throw ConnectionServiceError.hostNotFound
        }
        try await coordinator.prepare(host: host, prompting: prompting)
        return try await coordinator.exec(host: host, command: command)
    }

    private func connectHeadless(hostID: UUID) async throws -> UUID {
        guard let host = try await hostRepository.host(id: hostID), !host.isDeleted else {
            throw ConnectionServiceError.hostNotFound
        }
        if publishing.insert(hostID).inserted {
            Task { await publishStates(hostID: hostID) }
        }
        try await coordinator.prepare(host: host, prompting: prompting)
        let handle = try await coordinator.openSession(
            host: host,
            terminal: .other,
            size: TerminalSize(columns: 120, rows: 32),
            persistence: .none
        )
        headless[handle.id] = HeadlessSession(hostID: host.id, hostName: host.displayName, output: "")
        Task { await self.pump(handle) }
        return handle.id
    }

    private func pump(_ handle: SSHSessionHandle) async {
        for await event in handle.events {
            switch event {
            case .stdout(let data), .stderr(let data):
                appendOutput(String(decoding: data, as: UTF8.self), sessionID: handle.id)
            case .status(let message):
                appendOutput(message, sessionID: handle.id)
            case .exited:
                break
            }
        }
        headless[handle.id] = nil
    }

    private func appendOutput(_ chunk: String, sessionID: UUID) {
        guard var session = headless[sessionID] else { return }
        session.output += chunk
        if session.output.count > 200_000 {
            session.output = String(session.output.suffix(160_000))
        }
        headless[sessionID] = session
    }

    private func makeCommand(hostID: UUID) async throws -> String {
        guard let host = try await hostRepository.host(id: hostID), !host.isDeleted else {
            throw ConnectionServiceError.hostNotFound
        }
        try await coordinator.prepare(host: host, prompting: prompting)
        let descriptor = try await broker.createDescriptor(host: host, terminal: .other)
        let helper = try terminalLauncher.attachHelperURL()
        return await broker.command(for: descriptor, helperURL: helper)
    }

    private func publishStates(hostID: UUID) async {
        let stream = await coordinator.states(for: hostID)
        for await phase in stream {
            broadcast(.phase(hostID: hostID, phase))
        }
    }

    private func waitForSubscriber() async {
        for _ in 0..<150 {
            if clients.values.contains(where: \.subscribed) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func broadcast(_ event: ConnectionControlEvent) {
        for client in clients.values where client.subscribed {
            write(.event(event), to: client.channel)
        }
    }

    private func write(_ frame: ConnectionControlFrame, to channel: Channel) {
        guard let data = try? ConnectionControlCodec.line(from: frame) else { return }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(buffer, promise: nil)
        }
    }
}

extension ConnectionServiceRuntime: ConnectionPromptRouting {}

public protocol ConnectionTerminalLaunching: Sendable {
    func attachHelperURL() throws -> URL
    @MainActor func launch(terminal: TerminalApplication, command: String, descriptor: AttachDescriptor) throws
    func revealTerminator() async
}

private struct HeadlessSession {
    var hostID: UUID
    var hostName: String
    var output: String
}

private struct ControlClient {
    var channel: Channel
    var subscribed = false
}

private final class ControlServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let runtime: ConnectionServiceRuntime
    private var buffer = ByteBuffer()

    init(runtime: ConnectionServiceRuntime) { self.runtime = runtime }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        Task { await runtime.register(channel) }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        let channel = context.channel
        Task { await runtime.unregister(channel) }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let line = readLine() {
            guard let frame = try? ConnectionControlCodec.frame(from: line) else { continue }
            let channel = context.channel
            Task { await runtime.handle(frame, from: channel) }
        }
    }

    private func readLine() -> Data? {
        guard let index = buffer.readableBytesView.firstIndex(of: 0x0A) else { return nil }
        let length = index - buffer.readableBytesView.startIndex
        let bytes = buffer.readBytes(length: length) ?? []
        buffer.moveReaderIndex(forwardBy: 1)
        return Data(bytes)
    }
}
