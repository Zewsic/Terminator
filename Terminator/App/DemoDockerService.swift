import TerminatorCore

actor DemoDockerService: DockerService {
    private var containers = [
        ContainerSummary(
            id: "demo-gateway",
            name: "gateway",
            image: "nginx:stable",
            state: "running",
            endpointName: "Demo · Production"
        ),
        ContainerSummary(
            id: "demo-postgres",
            name: "postgres",
            image: "postgres:17",
            state: "healthy",
            endpointName: "Demo · Home lab"
        ),
        ContainerSummary(
            id: "demo-worker",
            name: "worker",
            image: "terminator/worker:dev",
            state: "exited",
            endpointName: "Demo · Home lab"
        ),
    ]

    func listContainers() -> [ContainerSummary] { containers }

    func start(containerID: String) {
        update(containerID: containerID, state: "running")
    }

    func stop(containerID: String) {
        update(containerID: containerID, state: "exited")
    }

    private func update(containerID: String, state: String) {
        guard let index = containers.firstIndex(where: { $0.id == containerID }) else { return }
        containers[index].state = state
    }
}
