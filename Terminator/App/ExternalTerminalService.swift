#if !APP_STORE
import AppKit
import Foundation
import TerminatorCore
import TerminatorSSH

actor MacExternalTerminalService: ExternalTerminalConnecting {
    private let client: ConnectionServiceClient

    init(client: ConnectionServiceClient) {
        self.client = client
    }

    func installedApplications() async -> [TerminalApplication] {
        await MainActor.run {
            TerminalApplication.allCases.filter { terminal in
                terminal == .other || applicationURL(for: terminal) != nil
            }
        }
    }

    func connect(host: HostProfile, terminal: TerminalApplication) async throws {
        try await client.connect(host: host, terminal: terminal)
    }

    func makeConnectionCommand(host: HostProfile) async throws -> String {
        try await client.makeConnectionCommand(host: host)
    }

    func state(for hostID: UUID) async -> SSHConnectionPhase {
        await client.state(for: hostID)
    }

    func states(for hostID: UUID) async -> AsyncStream<SSHConnectionPhase> {
        await client.states(for: hostID)
    }

    func disconnect(hostID: UUID) async {
        await client.disconnect(hostID: hostID)
    }
}

#endif

