import Foundation
import TerminatorCore

public actor MockSSHService: SSHService {
    private var states: [UUID: SSHConnectionState] = [:]

    public init() {}

    public func connect(to host: HostProfile) {
        states[host.id] = .connected
    }

    public func disconnect(hostID: UUID) {
        states[hostID] = .disconnected
    }

    public func state(for hostID: UUID) -> SSHConnectionState {
        states[hostID] ?? .disconnected
    }
}

public actor MockDockerService: DockerService {
    private var containers: [ContainerSummary]

    public init(containers: [ContainerSummary] = Fixtures.containers) {
        self.containers = containers
    }

    public func listContainers() -> [ContainerSummary] { containers }

    public func start(containerID: String) {
        update(containerID: containerID, state: "running")
    }

    public func stop(containerID: String) {
        update(containerID: containerID, state: "exited")
    }

    private func update(containerID: String, state: String) {
        guard let index = containers.firstIndex(where: { $0.id == containerID }) else { return }
        containers[index].state = state
    }
}

public enum Fixtures {
    public static let hosts = [
        HostProfile(displayName: "Production", hostname: "prod.example.com", username: "deploy", group: "Servers", tags: ["production"]),
        HostProfile(displayName: "Home lab", hostname: "192.168.1.20", username: "zewsic", group: "Personal", tags: ["docker", "lab"]),
    ]

    public static let containers = [
        ContainerSummary(id: "1", name: "gateway", image: "nginx:stable", state: "running", endpointName: "Demo · Production"),
        ContainerSummary(id: "2", name: "postgres", image: "postgres:17", state: "healthy", endpointName: "Demo · Home lab"),
        ContainerSummary(id: "3", name: "worker", image: "terminator/worker:dev", state: "exited", endpointName: "Demo · Home lab"),
    ]
}
