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
    func transportClosed(hostID: UUID, error: Error?) async {
        guard let pool = pools[hostID], !pool.intentionalClose else { return }
        pools[hostID] = nil
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
                    session.continuation.yield(.status("\r\n[Terminator: Reconnected]\r\n"))
                }
                setPhase(.connected, for: host.id)
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
        for session in sessions.values where session.hostID == hostID {
            session.continuation.yield(.status(message))
            _ = await session.log.append(kind: .status, data: data)
        }
    }

    static func endpoint(for host: HostProfile) -> String {
        let normalized = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return host.port == 22 ? normalized : "[\(normalized)]:\(host.port)"
    }
}
