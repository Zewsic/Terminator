import Foundation
import Observation
import TerminatorCore

extension TerminatorAppModel {
    public func resolvedUsername(for host: HostProfile) -> String {
        if case .manual(let username, _) = host.authentication { return username }
        guard let id = host.authentication.identityID else { return "" }
        return identities.first { $0.id == id }?.username ?? ""
    }

    public func connect(_ host: HostProfile, with terminal: TerminalApplication) async {
        guard capabilities.externalTerminal, let externalTerminalService else { return }
        connectionHost = host
        connectionTerminal = terminal
        connectionPhase = .resolving
        hostConnectionPhases[host.id] = .resolving
        beginMonitoringConnection(hostID: host.id, service: externalTerminalService)
        do {
            try await externalTerminalService.connect(host: host, terminal: terminal)
            connectionPhase = .connected
            hostConnectionPhases[host.id] = .connected
        } catch is CancellationError {
            connectionPhase = .disconnected
            hostConnectionPhases[host.id] = .disconnected
            stopMonitoringConnection(hostID: host.id)
        } catch {
            connectionPhase = .failed(message: error.localizedDescription)
            hostConnectionPhases[host.id] = .failed(message: error.localizedDescription)
            stopMonitoringConnection(hostID: host.id)
        }
    }

    public func connectionPhase(for hostID: UUID) -> SSHConnectionPhase {
        hostConnectionPhases[hostID] ?? .disconnected
    }

    public func disconnect(_ host: HostProfile) async {
        guard let externalTerminalService else { return }
        connectionPrompts.cancel()
        await externalTerminalService.disconnect(hostID: host.id)
        stopMonitoringConnection(hostID: host.id)
        hostConnectionPhases[host.id] = .disconnected
        if connectionHost?.id == host.id {
            connectionHost = nil
            connectionTerminal = nil
            connectionPhase = .disconnected
        }
    }

    public func retryConnection() async {
        guard let host = connectionHost, let terminal = connectionTerminal else { return }
        await connect(host, with: terminal)
    }

    public func makeConnectionCommand() async -> String? {
        guard let host = connectionHost, let externalTerminalService else { return nil }
        do {
            return try await externalTerminalService.makeConnectionCommand(host: host)
        } catch {
            present(error)
            return nil
        }
    }

    public func cancelConnectionPresentation() async {
        guard let host = connectionHost else {
            dismissConnection()
            return
        }
        if case .connected = connectionPhase {
            dismissConnection()
            return
        }
        connectionPrompts.cancel()
        if let externalTerminalService {
            await externalTerminalService.disconnect(hostID: host.id)
        }
        stopMonitoringConnection(hostID: host.id)
        hostConnectionPhases[host.id] = .disconnected
        connectionHost = nil
        connectionTerminal = nil
        connectionPhase = .disconnected
    }

    private func beginMonitoringConnection(
        hostID: UUID,
        service: any ExternalTerminalConnecting
    ) {
        connectionMonitors[hostID]?.cancel()
        connectionMonitors[hostID] = Task { [weak self] in
            let phases = await service.states(for: hostID)
            for await phase in phases {
                guard !Task.isCancelled, let self else { return }
                self.hostConnectionPhases[hostID] = phase
                if self.connectionHost?.id == hostID { self.connectionPhase = phase }
            }
        }
    }

    private func stopMonitoringConnection(hostID: UUID) {
        connectionMonitors[hostID]?.cancel()
        connectionMonitors[hostID] = nil
    }

    public func dismissConnection() {
        connectionPrompts.cancel()
        connectionHost = nil
        connectionTerminal = nil
        connectionPhase = .disconnected
    }

}
