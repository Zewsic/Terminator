import Foundation
import NIOCore
import NIOSSH
import TerminatorCore

enum DockerPollOutput {
    static func split(_ buffer: String) -> (payload: String, code: Int)? {
        guard let range = buffer.range(of: #"__TERMINATOR_DOCKER_(-?\d+)__"#, options: .regularExpression) else {
            return nil
        }
        let token = String(buffer[range])
        let prefix = "__TERMINATOR_DOCKER_"
        let codeText = token.dropFirst(prefix.count).dropLast(2)
        guard let code = Int(codeText) else { return nil }
        return (String(buffer[..<range.lowerBound]), code)
    }

    static func script(prefix: String) -> String {
        let words = prefix.split(separator: " ").map { "'\($0)'" }.joined(separator: " ")
        return """
        set -- \(words)
        while IFS= read -r op; do
          [ "$op" = poll ] || continue
          if ! "$@" ps -a --no-trunc --format '{{printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s" .ID .Names .Image .State .Status .Labels .Ports}}'; then
            printf '\\n__TERMINATOR_DOCKER_1__\\n'
            continue
          fi
          printf '\\n__TERMINATOR_DOCKER_%s__\\n' "$?"
        done
        """
    }
}

extension NIOSSHConnectionCoordinator {
    func openDockerShell(host: HostProfile, script: String) async throws {
        if let existing = dockerShells[host.id], existing.channel.isActive, !existing.closed { return }
        await closeDockerShell(hostID: host.id)
        guard let pool = pools[host.id], pool.channel.isActive else { throw SSHTransportError.sessionUnavailable }
        let hostID = host.id
        let bridge = SessionChannelBridge(
            size: TerminalSize(columns: 80, rows: 24),
            remoteCommand: script,
            onEvent: { [weak self] event in Task { await self?.dockerEvent(hostID, event) } },
            onClose: { [weak self] _ in Task { await self?.dockerClosed(hostID) } }
        )
        let transport = pool.channel
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
        dockerShells[hostID] = DockerShellState(channel: try await child.get())
    }

    func pollDockerShell(hostID: UUID) async throws -> (payload: String, code: Int) {
        guard var shell = dockerShells[hostID], shell.channel.isActive, !shell.closed else {
            throw SSHTransportError.sessionUnavailable
        }
        shell.buffer = ""
        dockerShells[hostID] = shell
        var buffer = shell.channel.allocator.buffer(capacity: 5)
        buffer.writeString("poll\n")
        try await shell.channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if let current = dockerShells[hostID], let split = DockerPollOutput.split(current.buffer) {
                return split
            }
            if dockerShells[hostID]?.closed == true || dockerShells[hostID]?.channel.isActive != true {
                await closeDockerShell(hostID: hostID)
                throw SSHTransportError.sessionUnavailable
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await closeDockerShell(hostID: hostID)
        throw SSHTransportError.sessionUnavailable
    }

    func closeDockerShell(hostID: UUID) async {
        guard let shell = dockerShells.removeValue(forKey: hostID) else { return }
        if shell.channel.isActive { try? await shell.channel.close().get() }
    }

    func dockerEvent(_ hostID: UUID, _ event: SSHSessionEvent) {
        guard var shell = dockerShells[hostID] else { return }
        if case .stdout(let data) = event {
            shell.buffer += String(decoding: data, as: UTF8.self)
            dockerShells[hostID] = shell
        }
    }

    func dockerClosed(_ hostID: UUID) {
        dockerShells[hostID]?.closed = true
    }
}
