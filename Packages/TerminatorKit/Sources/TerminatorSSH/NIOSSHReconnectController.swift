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
    func retain(host: HostProfile, prompting: any SSHConnectionPrompting) async {
        retainedHosts.insert(host.id)
        if pools[host.id]?.channel.isActive == true { return }
        if reconnectTasks[host.id] != nil { return }
        if let pending = prepareTasks[host.id] {
            _ = try? await pending.value
            if pools[host.id]?.channel.isActive == true || !retainedHosts.contains(host.id) || reconnectTasks[host.id] != nil {
                return
            }
        }
        reconnectTasks[host.id] = Task { [weak self] in
            await self?.reconnect(host: host, prompting: prompting)
        }
    }

    func isRetained(_ hostID: UUID) -> Bool { retainedHosts.contains(hostID) }

    func isPoolActive(_ hostID: UUID) -> Bool { pools[hostID]?.channel.isActive == true }
    func releaseRetention(_ hostID: UUID) {
        retainedHosts.remove(hostID)
        reconnectTasks[hostID]?.cancel()
        reconnectTasks[hostID] = nil
    }


    func transportClosed(hostID: UUID, error: Error?) async {
        guard let pool = pools[hostID], !pool.intentionalClose else { return }
        pools[hostID] = nil
        await suspendTunnels(touching: hostID)
        guard retainedHosts.contains(hostID) else {
            setPhase(.disconnected, for: hostID)
            return
        }
        guard reconnectTasks[hostID] == nil else { return }
        await broadcastStatus("\r\n[Terminator: Reconnecting...]\r\n", hostID: hostID)
        reconnectTasks[hostID] = Task { [weak self] in await self?.reconnect(host: pool.host, prompting: pool.prompting) }
    }

    func reconnect(host: HostProfile, prompting: any SSHConnectionPrompting) async {
        var attempt = 0
        while !Task.isCancelled && retainedHosts.contains(host.id) {
            attempt += 1
            setPhase(.reconnecting(attempt: attempt), for: host.id)
            if attempt > 1 {
                await broadcastStatus("\r\n[Terminator: Reconnecting...]\r\n", hostID: host.id)
            }
            do {
                try await establish(host: host, prompting: prompting)
                guard let transport = pools[host.id]?.channel else { throw SSHTransportError.sessionUnavailable }
                let ids = sessions.filter { $0.value.hostID == host.id }.map(\.key)
                for id in ids {
                    guard var session = sessions[id] else { continue }
                    session.channel = try await createSessionChannel(
                        transport: transport, sessionID: id, size: session.size, remoteCommand: session.remoteCommand
                    )
                    sessions[id] = session
                    await session.log.markReconnect()
                    emit(.status("\r\n[Terminator: Reconnected]\r\n"), sessionID: id)
                }
                publishLink(for: host.id)
                await resumeTunnels(touching: host.id)
                reconnectTasks[host.id] = nil
                return
            } catch {
                setPhase(.failed(message: error.localizedDescription), for: host.id)
                let seconds = min(30.0, pow(2.0, Double(min(attempt - 1, 5))))
                await broadcastStatus(
                    "\r\n[Terminator: Reconnecting... attempt \(attempt) failed, retry in \(Int(seconds))s]\r\n",
                    hostID: host.id
                )
                try? await Task.sleep(for: .seconds(seconds + Double.random(in: 0 ... 0.5)))
            }
        }
        reconnectTasks[host.id] = nil
    }

    func broadcastStatus(_ message: String, hostID: UUID) async {
        let data = Data(message.utf8)
        let ids = sessions.filter { $0.value.hostID == hostID }.map(\.key)
        for id in ids {
            emit(.status(message), sessionID: id)
            if let session = sessions[id] {
                _ = await session.log.append(kind: .status, data: data)
            }
        }
    }

    static func endpoint(for host: HostProfile) -> String {
        let normalized = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return host.port == 22 ? normalized : "[\(normalized)]:\(host.port)"
    }
}
