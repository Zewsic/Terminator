import Foundation
import TerminatorCore

private enum PollOutcome: Sendable {
    case containers([DockerContainer])
    case absent
    case failed
}

private struct HostPoll: Sendable {
    var endpoint: DockerEndpoint
    var outcome: PollOutcome?
}

actor DockerPoller {
    private let coordinator: NIOSSHConnectionCoordinator
    private let hostRepository: any HostRepository
    private let publish: @Sendable (DockerInventorySnapshot) async -> Void
    private var task: Task<Void, Never>?
    private var cached: [String: [DockerContainer]] = [:]

    init(
        coordinator: NIOSSHConnectionCoordinator,
        hostRepository: any HostRepository,
        publish: @escaping @Sendable (DockerInventorySnapshot) async -> Void
    ) {
        self.coordinator = coordinator
        self.hostRepository = hostRepository
        self.publish = publish
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let waiting = await self.endpointsAwaitingFirstPoll()
                if !waiting.isEmpty {
                    await self.publish(await self.snapshot(updating: waiting, failed: self.lastFailed))
                }
                let snapshot = await self.collect()
                await self.publish(snapshot)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var lastFailed: [DockerEndpoint] = []

    private func snapshot(updating: [DockerEndpoint], failed: [DockerEndpoint]) -> DockerInventorySnapshot {
        DockerInventorySnapshot(containers: cachedContainers, updating: updating, failed: failed)
    }

    private var cachedContainers: [DockerContainer] {
        cached.values.flatMap { $0 }
    }

    private func endpointsAwaitingFirstPoll() async -> [DockerEndpoint] {
        var waiting: [DockerEndpoint] = []
        if cached[DockerEndpoint.mac.cacheKey] == nil { waiting.append(.mac) }
        let hosts = (try? await hostRepository.listHosts(includeDeleted: false)) ?? []
        for host in hosts {
            let active = await coordinator.isPoolActive(host.id)
            let retained = await coordinator.isRetained(host.id)
            guard active || retained else { continue }
            if cached[host.id.uuidString] == nil {
                waiting.append(.host(id: host.id, name: host.displayName))
            }
        }
        return waiting
    }

    private func collect() async -> DockerInventorySnapshot {
        let hosts = (try? await hostRepository.listHosts(includeDeleted: false)) ?? []
        var updating: [DockerEndpoint] = []

        switch await pollLocal() {
        case .containers(let containers):
            cached[DockerEndpoint.mac.cacheKey] = containers
        case .absent, .failed:
            updating.append(.mac)
        }
        var pending = updating
        for host in hosts {
            let active = await coordinator.isPoolActive(host.id)
            let retained = await coordinator.isRetained(host.id)
            guard active || retained else { continue }
            pending.append(.host(id: host.id, name: host.displayName))
        }
        await publish(snapshot(updating: pending, failed: lastFailed))

        let polls = await withTaskGroup(of: HostPoll.self, returning: [HostPoll].self) { group in
            for host in hosts {
                let endpoint = DockerEndpoint.host(id: host.id, name: host.displayName)
                let active = await coordinator.isPoolActive(host.id)
                let retained = await coordinator.isRetained(host.id)
                if !active && !retained {
                    cached[endpoint.cacheKey] = nil
                    continue
                }
                if !active {
                    group.addTask { HostPoll(endpoint: endpoint, outcome: nil) }
                    continue
                }
                group.addTask {
                    HostPoll(endpoint: endpoint, outcome: await self.poll(host))
                }
            }
            var collected: [HostPoll] = []
            for await poll in group { collected.append(poll) }
            return collected
        }

        var seen: Set<String> = [DockerEndpoint.mac.cacheKey]
        var absent: [DockerEndpoint] = []
        for poll in polls {
            seen.insert(poll.endpoint.cacheKey)
            switch poll.outcome {
            case .containers(let containers):
                cached[poll.endpoint.cacheKey] = containers
            case .absent:
                absent.append(poll.endpoint)
            case .failed, nil:
                updating.append(poll.endpoint)
            }
        }
        for key in cached.keys where !seen.contains(key) {
            cached[key] = nil
        }
        lastFailed = absent
        return DockerInventorySnapshot(containers: cachedContainers, updating: updating, failed: absent)
    }

    private func poll(_ host: HostProfile) async -> PollOutcome {
        guard await coordinator.isPoolActive(host.id) else { return .failed }
        let prefix = host.dockerCommandPrefix.isEmpty ? DockerCommandPrefix.fallback : host.dockerCommandPrefix
        let endpoint = DockerEndpoint.host(id: host.id, name: host.displayName)
        do {
            try await coordinator.openDockerShell(host: host, script: DockerPollOutput.script(prefix: prefix))
            let result = try await coordinator.pollDockerShell(hostID: host.id)
            guard result.code == 0 else { return .absent }
            return .containers(DockerInventory.parseList(result.payload, endpoint: endpoint))
        } catch {
            await coordinator.closeDockerShell(hostID: host.id)
            return .failed
        }
    }

    private func pollLocal() async -> PollOutcome {
        let script = """
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
        command -v docker >/dev/null 2>&1 || exit 127
        docker ps -a --no-trunc --format '{{printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s" .ID .Names .Image .State .Status .Labels .Ports}}' || exit 1
        printf '\\n---FACTS---\\n'
        docker ps -a --format '{{.Image}}' | sort -u | while IFS= read -r image; do
          [ -n "$image" ] || continue
          kind=$(docker image inspect --format '{{if .RepoDigests}}remote{{else}}local{{end}}' "$image" 2>/dev/null || printf remote)
          printf '%s\\t%s\\t' "$image" "$kind"
          if [ "$kind" = local ]; then
            docker image history --no-trunc --format '{{.CreatedBy}}' "$image" 2>/dev/null | tr '\\n' '\\036'
          fi
          printf '\\n'
        done
        """
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return .failed }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 127 { return .containers([]) }
            guard process.terminationStatus == 0 else { return .failed }
            return .containers(DockerInventory.parsePoll(String(decoding: data, as: UTF8.self), endpoint: .mac))
        }.value
    }
}
