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
        if connectionPhase(for: host.id).isLinked {
            await connectInBackground(host, with: terminal)
            return
        }
        guard capabilities.externalTerminal, let externalTerminalService else { return }
        connectionHost = host
        connectionTerminal = terminal
        connectionPhase = .resolving
        hostConnectionPhases[host.id] = .resolving
        beginMonitoringConnection(hostID: host.id, service: externalTerminalService)
        do {
            let detectedOS = try await externalTerminalService.connect(host: host, terminal: terminal)
            connectionPhase = .connected
            hostConnectionPhases[host.id] = .connected
            HostListPreferences.shared.noteConnected(host.id)
            await applyDetectedOS(detectedOS, to: host.id)
            Task { await self.refreshDetectedOS(hostID: host.id) }
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

    /// Starts a connection without presenting Terminator. If the SSH exchange
    /// needs user input, `revealBackgroundConnectionIfNeeded()` presents the
    /// existing connection sheet and the exchange resumes from that prompt.
    public func connectInBackground(_ host: HostProfile, with terminal: TerminalApplication) async {
        guard capabilities.externalTerminal, let externalTerminalService else { return }
        backgroundConnectionHost = host
        connectionTerminal = terminal
        if (hostConnectionPhases[host.id] ?? .disconnected).isLinked {
        } else {
            hostConnectionPhases[host.id] = .resolving
        }
        beginMonitoringConnection(hostID: host.id, service: externalTerminalService)
        do {
            let detectedOS = try await externalTerminalService.connect(host: host, terminal: terminal)
            hostConnectionPhases[host.id] = .connected
            HostListPreferences.shared.noteConnected(host.id)
            if connectionHost?.id != host.id { backgroundConnectionHost = nil }
            await applyDetectedOS(detectedOS, to: host.id)
            Task { await self.refreshDetectedOS(hostID: host.id) }
        } catch is CancellationError {
            hostConnectionPhases[host.id] = .disconnected
            stopMonitoringConnection(hostID: host.id)
            if connectionHost?.id == host.id { connectionPhase = .disconnected }
            backgroundConnectionHost = nil
        } catch {
            hostConnectionPhases[host.id] = .failed(message: error.localizedDescription)
            stopMonitoringConnection(hostID: host.id)
            if connectionHost?.id == host.id { connectionPhase = .failed(message: error.localizedDescription) }
            backgroundConnectionHost = nil
        }
    }

    public func connectInBackground(hostID: UUID, with terminal: TerminalApplication) async {
        do {
            guard let host = try await hostRepository.host(id: hostID), !host.isDeleted else { return }
            await connectInBackground(host, with: terminal)
        } catch {
            return
        }
    }

    public func revealBackgroundConnectionIfNeeded() {
        guard connectionHost == nil, let host = backgroundConnectionHost else { return }
        connectionHost = host
        connectionPhase = hostConnectionPhases[host.id] ?? .resolving
        revealMainWindow()
    }

    public func revealMainWindow() {
        shouldRevealMainWindow = true
    }

    public func answerServicePrompt(_ envelope: ConnectionPromptEnvelope) async -> ConnectionPromptReply {
        if let hostID = envelope.hostID, let host = hosts.first(where: { $0.id == hostID }) {
            backgroundConnectionHost = host
        }
        revealBackgroundConnectionIfNeeded()
        shouldRevealMainWindow = true
        do {
            switch envelope.kind {
            case .passphrase(let credential):
                return .text(try await connectionPrompts.requestPassphrase(for: credential))
            case .username(let host):
                return .text(try await connectionPrompts.requestUsername(for: host))
            case .password(let host, let username):
                return .text(try await connectionPrompts.requestPassword(for: host, username: username))
            case .authentication(let host, let username, let keys, let identities):
                return .authentication(try await connectionPrompts.requestAuthentication(
                    for: host, username: username, availableAccessKeys: keys, availableIdentities: identities
                ))
            case .trustNewHost(let key):
                return try await connectionPrompts.trustNewHost(key) ? .confirmed : .cancelled
            case .replaceHostKey(let previous, let presented):
                return try await connectionPrompts.confirmChangedHost(previous: previous, presented: presented)
                    ? .confirmed : .cancelled
            case .keychain(let reason):
                try await connectionPrompts.requestKeychainAttention(reason: reason)
                return .confirmed
            }
        } catch {
            return .cancelled
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
        if connectionPhase.isLinked {
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
                if case .disconnected = phase { self.clearServiceStatus(hostID) }
                if case .failed = phase { self.clearServiceStatus(hostID) }
                if self.connectionHost?.id == hostID { self.connectionPhase = phase }
                if phase.isLinked {
                    HostListPreferences.shared.noteConnected(hostID)
                    Task { await self.refreshDetectedOS(hostID: hostID) }
                    Task { await self.startAutomaticTunnels(for: hostID) }
                }
            }
        }
    }

    func trackHostConnections() {
        guard let service = externalTerminalService else { return }
        let live = Set(hosts.map(\.id))
        for id in connectionMonitors.keys where !live.contains(id) {
            stopMonitoringConnection(hostID: id)
        }
        for host in hosts where connectionMonitors[host.id] == nil {
            beginMonitoringConnection(hostID: host.id, service: service)
        }
    }

    private func stopMonitoringConnection(hostID: UUID) {
        connectionMonitors[hostID]?.cancel()
        connectionMonitors[hostID] = nil
    }

    func applyDetectedOS(_ os: DetectedHostOS?, to hostID: UUID) async {
        guard let os else { return }
        do {
            let current = try await hostRepository.host(id: hostID)
            guard let current, current.detectedOS == nil else {
                await load()
                return
            }
            try await hostRepository.saveHost(current.applyingDetectedOS(os))
            await load()
        } catch {
            return
        }
    }

    func refreshDetectedOS(hostID: UUID) async {
        for _ in 0..<10 {
            if let cached = hosts.first(where: { $0.id == hostID }), cached.detectedOS != nil {
                return
            }
            let latest = try? await hostRepository.host(id: hostID)
            if let latest, latest.detectedOS != nil {
                await load()
                return
            }
            if let latest {
                await detectOperatingSystemIfNeeded(latest)
                if hosts.first(where: { $0.id == hostID })?.detectedOS != nil { return }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    func detectOperatingSystemIfNeeded(_ host: HostProfile) async {
        guard host.detectedOS == nil, let externalTerminalService else { return }
        do {
            if let latest = try await hostRepository.host(id: host.id), latest.detectedOS != nil {
                await load()
                return
            }
        } catch {
            return
        }
        let posix = try? await externalTerminalService.exec(host: host, command: HostOSProbe.posixCommand)
        var detected = posix.flatMap { HostOSProbe.parse($0.stdout + "\n" + $0.stderr) }
        if detected == nil {
            let windows = try? await externalTerminalService.exec(host: host, command: HostOSProbe.windowsCommand)
            detected = windows.flatMap { HostOSProbe.parse($0.stdout + "\n" + $0.stderr) }
        }
        guard let detected else { return }
        do {
            let current = try await hostRepository.host(id: host.id) ?? host
            guard current.detectedOS == nil else {
                await load()
                return
            }
            try await hostRepository.saveHost(current.applyingDetectedOS(detected))
            await load()
        } catch {
            return
        }
    }

    public func dismissConnection() {
        connectionPrompts.cancel()
        connectionHost = nil
        connectionTerminal = nil
        connectionPhase = .disconnected
    }

}
