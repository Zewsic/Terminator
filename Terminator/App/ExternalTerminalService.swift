#if !APP_STORE
import AppKit
import Foundation
import TerminatorCore
import TerminatorFeatures
import TerminatorSSH
actor MacExternalTerminalService: ExternalTerminalConnecting {
    private let coordinator: any SSHConnectionCoordinating
    private let broker: TerminalAttachBroker
    private let prompting: MacConnectionPrompter

    init(coordinator: any SSHConnectionCoordinating, broker: TerminalAttachBroker, prompting: MacConnectionPrompter) {
        self.coordinator = coordinator
        self.broker = broker
        self.prompting = prompting
    }

    func installedApplications() async -> [TerminalApplication] {
        await MainActor.run {
            TerminalApplication.allCases.filter { terminal in
                terminal == .other || applicationURL(for: terminal) != nil
            }
        }
    }

    func connect(host: HostProfile, terminal: TerminalApplication) async throws {
        do {
            try await coordinator.prepare(host: host, prompting: prompting)
            let descriptor = try await broker.createDescriptor(host: host, terminal: terminal)
            do {
                let helper = try await MainActor.run { try helperURL() }
                let command = await broker.command(for: descriptor, helperURL: helper)
                try await MainActor.run { try launch(terminal: terminal, command: command, descriptor: descriptor) }
            } catch {
                await broker.cancel(descriptor)
                throw error
            }
        } catch {
            await coordinator.disconnect(hostID: host.id)
            throw error
        }
    }

    func makeConnectionCommand(host: HostProfile) async throws -> String {
        try await coordinator.prepare(host: host, prompting: prompting)
        let descriptor = try await broker.createDescriptor(host: host, terminal: .other)
        do {
            let helper = try await MainActor.run { try helperURL() }
            return await broker.command(for: descriptor, helperURL: helper)
        } catch {
            await broker.cancel(descriptor)
            throw error
        }
    }

    func state(for hostID: UUID) async -> SSHConnectionPhase {
        await coordinator.state(for: hostID)
    }

    func states(for hostID: UUID) async -> AsyncStream<SSHConnectionPhase> {
        await coordinator.states(for: hostID)
    }

    func disconnect(hostID: UUID) async {
        await coordinator.disconnect(hostID: hostID)
    }
}

#endif
