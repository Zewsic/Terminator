import Foundation
import Testing
@testable import TerminatorCore

@Suite("Docker inventory")
struct DockerInventoryTests {
    @Test("Parses inspect lines and groups compose before hosts")
    func parsesInspect() {
        let hostID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let endpoint = DockerEndpoint.host(id: hostID, name: "Edge")
        let image = String(repeating: "ab", count: 32)
        let compose = """
        {"Id":"abc123","Name":"/web","Config":{"Image":"nginx:latest","Labels":{"com.docker.compose.project":"edge"}},"Image":"sha256:\(image)","State":{"Status":"running","Health":{"Status":"healthy"}}}
        """
        let plain = """
        {"Id":"def456","Name":"/db","Config":{"Image":"postgres:16","Labels":{}},"Image":"sha256:\(image)","State":{"Status":"exited"}}
        """
        let containers = DockerInventory.parseInspect("not-json\n\(compose)\n\n\(plain)\n", endpoint: endpoint)
        #expect(containers.count == 2)
        #expect(containers[0].name == "web")
        #expect(containers[0].imageID == String(image.prefix(12)))
        #expect(containers[0].health == "healthy")
        #expect(containers[0].placement == .compose(project: "edge", hostID: hostID, hostName: "Edge"))
        #expect(containers[1].name == "db")
        #expect(containers[1].placement == .host(id: hostID, name: "Edge"))
        let titles = DockerInventory.sections(containers).map { DockerInventory.sectionTitle($0.placement) }
        #expect(titles == ["edge · Edge", "Edge"])
    }

    @Test("Swarm labels outrank compose labels")
    func swarmOutranksCompose() {
        let endpoint = DockerEndpoint.host(id: UUID(), name: "Swarm")
        let line = """
        {"Id":"1","Name":"/api","Config":{"Image":"api","Labels":{"com.docker.stack.namespace":"prod","com.docker.compose.project":"api"}},"Image":"sha256:aaaaaaaaaaaa","State":{"Status":"running"}}
        """
        let containers = DockerInventory.parseInspect(line, endpoint: endpoint)
        #expect(containers.first?.placement == .swarm(name: "prod"))
    }

    @Test("Mac containers split into compose, swarm, and loose")
    func macSplitsStacksAndProjects() {
        let payload = """
        {"Id":"1","Name":"/api","Config":{"Image":"api","Labels":{"com.docker.stack.namespace":"prod","com.docker.compose.project":"api"}},"Image":"sha256:aaaaaaaaaaaa","State":{"Status":"running"}}
        {"Id":"2","Name":"/web","Config":{"Image":"nginx","Labels":{"com.docker.compose.project":"site"}},"Image":"sha256:bbbbbbbbbbbb","State":{"Status":"running"}}
        {"Id":"3","Name":"/solo","Config":{"Image":"redis","Labels":{}},"Image":"sha256:cccccccccccc","State":{"Status":"exited"}}
        """
        let containers = DockerInventory.parseInspect(payload, endpoint: .mac)
        #expect(containers.map(\.placement) == [
            .swarm(name: "prod"),
            .compose(project: "site", hostID: DockerInventory.localComposeHostID, hostName: ""),
            .mac
        ])
        let sections = DockerInventory.sections(containers)
        #expect(sections.map { DockerInventory.sectionTitle($0.placement) } == ["site", "prod", ""])
        #expect(sections.map(\.id) == [
            "compose:site:\(DockerInventory.localComposeHostID.uuidString)",
            "swarm:prod",
            "mac"
        ])
    }

    @Test("Hub ids drop tags, digests, and foreign registries")
    func hubRepositoryIDs() {
        #expect(DockerHubRepository.id(from: "nginx:latest") == "library/nginx")
        #expect(DockerHubRepository.id(from: "nginx@sha256:abc") == "library/nginx")
        #expect(DockerHubRepository.id(from: "docker.io/library/redis:7") == "library/redis")
        #expect(DockerHubRepository.id(from: "Grafana/Grafana:10") == "grafana/grafana")
        #expect(DockerHubRepository.id(from: "ghcr.io/foo/bar:1") == nil)
        #expect(DockerHubRepository.id(from: "localhost:5000/foo:latest") == nil)
    }

    @Test("Nests compose under its host and keeps swarm separate")
    func browserGroupsNestCompose() {
        let hostID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let endpoint = DockerEndpoint.host(id: hostID, name: "X-Studio")
        let containers = [
            container("b", "beta", placement: .compose(project: "beta", hostID: hostID, hostName: "X-Studio"), endpoint: endpoint),
            container("a", "alpha", placement: .compose(project: "alpha", hostID: hostID, hostName: "X-Studio"), endpoint: endpoint),
            container("s", "solo", placement: .host(id: hostID, name: "X-Studio"), endpoint: endpoint),
            container("w", "worker", placement: .swarm(name: "prod"), endpoint: endpoint),
        ]
        let groups = DockerInventory.browserGroups(containers, macTitle: "This Mac")
        #expect(groups.map(\.title) == ["SWARM: prod", "X-Studio"])
        #expect(groups[1].sections.map(\.title) == ["alpha", "beta", nil])
        #expect(groups[1].sections.map { $0.containers.map(\.name) } == [["alpha"], ["beta"], ["solo"]])
    }

    @Test("Reads published ports from docker ps and inspect")
    func readsPublishedPorts() {
        #expect(DockerPublishedPort.parse("0.0.0.0:8080->80/tcp, :::8080->80/tcp, 443/tcp").map(\.binding) == ["8080 → 80/tcp"])
        let endpoint = DockerEndpoint.mac
        let line = "abc\tweb\tnginx\trunning\tUp\t\t127.0.0.1:5432->5432/tcp"
        let containers = DockerInventory.parseList(line, endpoint: endpoint)
        #expect(containers.first?.ports.map(\.tunnelTargetAddress) == ["127.0.0.1"])
        #expect(containers.first?.ports.first?.containerPort == 5432)
    }

    @Test("Reads a Dockerfile FROM line and a local image fact")
    func readsBaseImage() {
        #expect(DockerInventory.baseImage(from: [
            "CMD [\"python\"]",
            "/bin/sh -c #(nop)  FROM python:3.12-alpine@sha256:abc",
        ]) == "python:3.12-alpine")
        let payload = """
        abc\tsolo\tmyapp:latest\trunning\tUp\t
        ---FACTS---
        myapp:latest\tlocal\tFROM python:3.12
        """
        let parsed = DockerInventory.parsePoll(payload, endpoint: .mac)
        #expect(parsed.first?.builtLocally == true)
        #expect(parsed.first?.baseImage == "python:3.12")
    }

    private func container(
        _ id: String,
        _ name: String,
        placement: DockerPlacement,
        endpoint: DockerEndpoint
    ) -> DockerContainer {
        DockerContainer(
            id: id,
            name: name,
            image: name,
            imageID: id,
            state: "running",
            health: nil,
            endpoint: endpoint,
            placement: placement
        )
    }
}

@Suite("Authorized key lines")
struct AuthorizedKeyLineTests {
    @Test("Accepts one OpenSSH line and rejects extras")
    func validates() {
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyValue terminator"
        #expect(AuthorizedKeyLine.validate(line) == line)
        #expect(AuthorizedKeyLine.validate("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyValue\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther") == nil)
        #expect(AuthorizedKeyLine.validate("ssh-ed25519") == nil)
        #expect(AuthorizedKeyLine.validate("ssh-ed25519 abc$def") == nil)
        let command = AuthorizedKeyLine.installCommand(line)
        #expect(command?.contains("grep -qxF") == true)
        #expect(command?.contains("'\(line)'") == true)
        #expect(AuthorizedKeyLine.installCommand("$(reboot)") == nil)
    }
}

@Suite("Desired work")
struct DesiredWorkTests {
    @Test("Persists terminals and tunnels across a new store")
    func persists() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "desired-work-\(UUID().uuidString)")
        let hostID = UUID()
        let tunnelID = UUID()
        let store = DesiredWorkStore(directory: directory)
        await store.addTerminal(DesiredTerminal(token: "token", hostID: hostID, columns: 80, rows: 24))
        await store.addTunnel(tunnelID)
        await store.updateTerminal(token: "token", columns: 120, rows: 40)
        let reloaded = DesiredWorkStore(directory: directory)
        let work = await reloaded.current()
        #expect(work.tunnelIDs == [tunnelID])
        #expect(work.terminals == [DesiredTerminal(token: "token", hostID: hostID, columns: 120, rows: 40)])
        await reloaded.removeTerminal(token: "token")
        await reloaded.removeTunnel(tunnelID)
        let cleared = await DesiredWorkStore(directory: directory).current()
        #expect(cleared.terminals.isEmpty)
        #expect(cleared.tunnelIDs.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Container runtime")
struct DockerRuntimeStatusTests {
    @Test("Disk is the writable layer, not cumulative block I/O")
    func diskIsWritableLayer() throws {
        let payload = """
        {"State":{"StartedAt":"2024-01-01T00:00:00Z"},"RestartCount":0,"SizeRw":4096,"Mounts":[]}
        __TERMINATOR_SPLIT__
        {"CPUPerc":"0.00%","MemUsage":"74.7MiB / 2GiB","NetIO":"79.9MB / 1MB","BlockIO":"289.64GB / 12kB"}
        """
        let status = try #require(DockerRuntimeStatus.parse(payload))
        #expect(status.diskUsed == 4096)
        #expect((status.blockRead ?? 0) > 1_000_000_000)
    }
}

@Suite("Host status")
struct HostStatusTests {
    @Test("Parses Linux totals and ignores the aggregate cpu line")
    func parsesLinux() {
        let hostID = UUID()
        let text = """
        UPTIME 3661
        LOAD 0.5 0.4 0.3
        CORE cpu 10.0
        CORE CPU1 25.0
        MEM 1000 400 600 0 0 100
        DISK\tsda\text4\t2000\t500\t10\t20\t/
        NET 100 50
        PROC\t12\t150\t0\t0\t0\troot\tsshd
        """
        let snapshot = HostStatusReport.parse(text, hostID: hostID, collectedAt: Date(timeIntervalSince1970: 0))
        #expect(snapshot?.uptime == 3661)
        #expect(snapshot?.load1 == 0.5)
        #expect(snapshot?.averageCPU == 0.25)
        #expect(snapshot?.memory.used == 400)
        #expect(snapshot?.disks.first?.mount == "/")
        #expect(snapshot?.network.receiveBytesPerSecond == 100)
        #expect(snapshot?.processes.first?.name == "sshd")
        #expect(DockerControl.command(prefix: "docker", action: .start, containerID: "abc") == "docker start abc")
        #expect(DockerControl.command(prefix: "docker", action: .start, containerID: "bad id") == nil)
        #expect(DockerControl.shellCommand(prefix: "docker", containerID: "abc")?.contains("docker exec -it abc") == true)
    }
}
