import Foundation
import TerminatorCore

extension TerminatorAppModel {
    func startHelperPolling() {
        helperInstallations = HelperStore.load()
        helperPoller?.cancel()
        helperPoller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.adoptRunningHelpers()
                await self.pollInstalledHelpers()
                await self.updateOutdatedHelpers()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func canInstallHelper(_ host: HostProfile) -> Bool {
        guard hosts.contains(where: { $0.id == host.id }) else { return false }
        guard !helperInstallations.contains(where: { $0.hostID == host.id }) else { return false }
        guard connectionPhase(for: host.id).isLinked else { return false }
        return dockerProbed.contains(host.id) && !dockerFailed.contains(host.id)
    }

    func isDockerMissing(_ host: HostProfile) -> Bool {
        guard connectionPhase(for: host.id).isLinked else { return false }
        guard !helperInstallations.contains(where: { $0.hostID == host.id }) else { return false }
        return dockerFailed.contains(host.id)
    }

    func isHelperOnline(_ hostID: UUID) -> Bool {
        helperOnline.contains(hostID)
    }

    func installHelper(on host: HostProfile, progress: (String) -> Void) async throws {
        progress(FeatureL10n.text(.helperInstallPreparing))
        let material = try await Task.detached(priority: .userInitiated) {
            try HelperMaterial.generate()
        }.value
        let secretID = SecretID()
        do {
            try await secretStore.store(Data(material.token.utf8), for: secretID, access: .deviceOnly)
        } catch {
            throw HelperInstallError.remote(error.localizedDescription)
        }
        guard let service = externalTerminalService else {
            try? await secretStore.purge(id: secretID)
            throw HelperInstallError.unavailable
        }
        progress(FeatureL10n.text(.helperInstallStarting))
        let command = HelperRemoteScript.command(prefix: host.dockerCommandPrefix, material: material)
        let result: SSHExecResult
        do {
            result = try await service.exec(host: host, command: command)
            try Task.checkCancellation()
        } catch is CancellationError {
            await abortInstall(secretID: secretID, hostID: host.id)
            throw CancellationError()
        } catch {
            try? await secretStore.purge(id: secretID)
            throw HelperInstallError.remote(error.localizedDescription)
        }
        guard result.exitCode == 0, result.stdout.contains("TERMINATOR_HELPER_STARTED") else {
            try? await secretStore.purge(id: secretID)
            throw HelperInstallError.remote(installFailureDetail(stderr: result.stderr, stdout: result.stdout, exitCode: result.exitCode))
        }
        let installation = HelperInstallation(
            hostID: host.id,
            port: HelperSnapshot.port,
            tokenSecretID: secretID,
            certificateDER: material.certificateDER
        )
        helperTokens[host.id] = material.token
        progress(FeatureL10n.text(.helperInstallOpening))
        do {
            let localPort = try await openHelperForward(for: host)
            var tunneled = installation
            tunneled.localPort = localPort
            if try await waitUntilOnline(host: host, installation: tunneled, token: material.token, seconds: 20) {
                try storeHelper(tunneled)
                return
            }
        } catch is CancellationError {
            await tunnelController?.stopTunnel(id: HelperForward.tunnelID(for: host.id))
            await abortInstall(secretID: secretID, hostID: host.id)
            throw CancellationError()
        } catch {
            await tunnelController?.stopTunnel(id: HelperForward.tunnelID(for: host.id))
        }
        progress(FeatureL10n.text(.helperInstallWaiting))
        do {
            if try await waitUntilOnline(host: host, installation: installation, token: material.token, seconds: 8) {
                try storeHelper(installation)
                return
            }
        } catch is CancellationError {
            await abortInstall(secretID: secretID, hostID: host.id)
            throw CancellationError()
        } catch {
            await abortInstall(secretID: secretID, hostID: host.id)
            throw HelperInstallError.remote(error.localizedDescription)
        }
        try? await secretStore.purge(id: secretID)
        helperTokens[host.id] = nil
        await tunnelController?.stopTunnel(id: HelperForward.tunnelID(for: host.id))
        let log = await helperFailureLog(service, host: host)
        let detail = "The helper is running, but \(host.hostname):\(HelperSnapshot.port) is not reachable from this Mac."
        throw HelperInstallError.remote(log == FeatureL10n.text(.helperTimedOut) ? detail : "\(detail)\n\(log)")
    }
    private func storeHelper(_ installation: HelperInstallation) throws {
        var stored = helperInstallations.filter { $0.hostID != installation.hostID }
        stored.append(installation)
        helperInstallations = stored
        try HelperStore.save(stored)
    }

    private func abortInstall(secretID: SecretID, hostID: UUID) async {
        try? await secretStore.purge(id: secretID)
        helperTokens[hostID] = nil
    }

    private func installFailureDetail(stderr: String, stdout: String, exitCode: Int) -> String {
        let lines = [stderr, stdout]
            .joined(separator: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(12).joined(separator: "\n")
        return tail.isEmpty ? "\(FeatureL10n.text(.helperTimedOut)) (exit \(exitCode))" : tail
    }

    private func waitUntilOnline(
        host: HostProfile,
        installation: HelperInstallation,
        token: String,
        seconds: TimeInterval
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try Task.checkCancellation()
            if await poll(host: host, installation: installation, token: token) { return true }
            try await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func openHelperForward(for host: HostProfile) async throws -> Int {
        guard let tunnelController else { throw HelperInstallError.unavailable }
        let port = HelperForward.localPort(for: host.id)
        let tunnel = TunnelProfile(
            id: HelperForward.tunnelID(for: host.id),
            displayName: "Helper",
            destination: .saved(host.id),
            listenAddress: "127.0.0.1",
            listenPort: port,
            targetAddress: "127.0.0.1",
            targetPort: HelperSnapshot.port
        )
        try await tunnelController.startTunnel(tunnel)
        return port
    }

    private func reachableEndpoint(
        host: HostProfile,
        installation: HelperInstallation
    ) async throws -> (hostname: String, port: Int) {
        guard let localPort = installation.localPort else {
            return (hostname: host.hostname, port: installation.port)
        }
        _ = try await openHelperForward(for: host)
        return (hostname: "127.0.0.1", port: localPort)
    }


    private func helperFailureLog(_ service: any ExternalTerminalConnecting, host: HostProfile) async -> String {
        let tool = host.dockerCommandPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DockerCommandPrefix.fallback
            : host.dockerCommandPrefix
        let installLog = (try? await service.exec(
            host: host,
            command: "tail -n 20 \"${HOME:-/tmp}/.terminator-helper/install.log\""
        ))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let containerLog = (try? await service.exec(
            host: host,
            command: "\(tool) logs --tail 20 terminator-helper 2>&1"
        ))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = [installLog, containerLog].filter { !$0.isEmpty }.joined(separator: "\n")
        return detail.isEmpty ? FeatureL10n.text(.helperTimedOut) : detail
    }

    func noteDocker(_ snapshot: DockerInventorySnapshot) {
        serviceDockerContainers = snapshot.containers
        serviceDockerUpdating = snapshot.updating
        serviceDockerReady = true
        let failedIDs = hostIDs(in: snapshot.failed)
        let updatingIDs = hostIDs(in: snapshot.updating)
        let probing = updatingIDs.subtracting(failedIDs)
        dockerFailed = failedIDs
        dockerProbed.formUnion(hostIDs(in: snapshot.containers.map(\.endpoint)))
        for id in dockerProbing where !probing.contains(id) && !failedIDs.contains(id) {
            dockerProbed.insert(id)
        }
        dockerProbed.subtract(failedIDs)
        dockerProbing = probing
        applyDockerInventory()
    }

    func noteServiceStatus(_ snapshot: HostStatusSnapshot) {
        guard !helperOnline.contains(snapshot.hostID) else { return }
        serviceHostStatuses[snapshot.hostID] = snapshot
        applyHostStatuses()
    }

    func clearServiceStatus(_ hostID: UUID) {
        serviceHostStatuses[hostID] = nil
        applyHostStatuses()
    }

    private func pollInstalledHelpers() async {
        struct Job: Sendable {
            var hostID: UUID
            var hostname: String
            var name: String
            var port: Int
            var token: String
            var certificateDER: Data
        }
        var jobs: [Job] = []
        for installation in helperInstallations {
            guard let host = hosts.first(where: { $0.id == installation.hostID }) else {
                markHelperOffline(installation.hostID)
                continue
            }
            guard let token = await token(for: installation) else {
                markHelperOffline(installation.hostID)
                continue
            }
            let reach = try? await reachableEndpoint(host: host, installation: installation)
            let endpoint = reach ?? (hostname: host.hostname, port: installation.port)
            jobs.append(Job(
                hostID: host.id,
                hostname: endpoint.hostname,
                name: host.displayName,
                port: endpoint.port,
                token: token,
                certificateDER: installation.certificateDER
            ))
        }
        let results = await withTaskGroup(of: (UUID, HelperPoll.Payload?).self) { group in
            for job in jobs {
                group.addTask {
                    let value = await HelperPoll.fetch(
                        hostname: job.hostname,
                        port: job.port,
                        token: job.token,
                        certificateDER: job.certificateDER,
                        hostID: job.hostID,
                        endpoint: .host(id: job.hostID, name: job.name)
                    )
                    return (job.hostID, value)
                }
            }
            var collected: [(UUID, HelperPoll.Payload?)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        for (id, value) in results {
            if let value {
                helperOnline.insert(id)
                helperStatuses[id] = value.snapshot
                helperContainers[id] = value.containers
                noteReportedVersion(value.version, hostID: id)
            } else {
                markHelperOffline(id)
            }
        }
        applyHostStatuses()
        applyDockerInventory()
    }

    @discardableResult
    private func poll(host: HostProfile, installation: HelperInstallation, token: String) async -> Bool {
        let endpoint: (hostname: String, port: Int)
        do {
            endpoint = try await reachableEndpoint(host: host, installation: installation)
        } catch {
            return false
        }
        let value = await HelperPoll.fetch(
            hostname: endpoint.hostname,
            port: endpoint.port,
            token: token,
            certificateDER: installation.certificateDER,
            hostID: host.id,
            endpoint: .host(id: host.id, name: host.displayName)
        )
        guard let value else { return false }
        helperOnline.insert(host.id)
        helperStatuses[host.id] = value.snapshot
        helperContainers[host.id] = value.containers
        noteReportedVersion(value.version, hostID: host.id)
        applyHostStatuses()
        applyDockerInventory()
        return true
    }

    private func token(for installation: HelperInstallation) async -> String? {
        if let token = helperTokens[installation.hostID] { return token }
        guard let data = try? await secretStore.read(id: installation.tokenSecretID),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        helperTokens[installation.hostID] = token
        return token
    }
    private func noteReportedVersion(_ version: String?, hostID: UUID) {
        guard let version, !version.isEmpty,
              let index = helperInstallations.firstIndex(where: { $0.hostID == hostID }),
              helperInstallations[index].version != version else { return }
        if helperUpdating.contains(hostID) { return }
        helperInstallations[index].version = version
        try? HelperStore.save(helperInstallations)
    }

    private func updateOutdatedHelpers() async {
        guard let service = externalTerminalService else { return }
        let now = Date()
        for installation in helperInstallations {
            guard HelperVersion.isOlder(installation.version, than: HelperSnapshot.version) else { continue }
            guard let host = hosts.first(where: { $0.id == installation.hostID }) else { continue }
            guard host.alwaysConnected || connectionPhase(for: host.id).isLinked else { continue }
            if helperUpdating.contains(host.id) { continue }
            if let after = helperUpdateAfter[host.id], after > now { continue }
            helperUpdating.insert(host.id)
            helperUpdateAfter[host.id] = now.addingTimeInterval(60)
            let updated = await updateHelper(on: host, installation: installation, service: service)
            helperUpdating.remove(host.id)
            if updated { helperUpdateAfter[host.id] = nil }
        }
    }

    private func updateHelper(
        on host: HostProfile,
        installation: HelperInstallation,
        service: any ExternalTerminalConnecting
    ) async -> Bool {
        let command = HelperRemoteScript.updateCommand(prefix: host.dockerCommandPrefix)
        guard let result = try? await service.exec(host: host, command: command),
              result.exitCode == 0,
              result.stdout.contains("TERMINATOR_HELPER_UPDATED") else { return false }
        var updated = installation
        updated.version = HelperSnapshot.version
        if updated.localPort == nil {
            updated.localPort = HelperForward.localPort(for: host.id)
        }
        do {
            try storeHelper(updated)
        } catch {
            return false
        }
        return true
    }

    private func adoptRunningHelpers() async {
        guard let service = externalTerminalService else { return }
        let now = Date()
        for host in hosts {
            guard host.alwaysConnected || connectionPhase(for: host.id).isLinked else { continue }
            guard !helperInstallations.contains(where: { $0.hostID == host.id }) else { continue }
            guard helperTokens[host.id] == nil else { continue }
            if let after = helperAdoptAfter[host.id], after > now { continue }
            helperAdoptAfter[host.id] = now.addingTimeInterval(20)
            if await adoptRunningHelper(on: host, service: service) {
                helperAdoptAfter[host.id] = nil
            }
        }
    }

    private func adoptRunningHelper(
        on host: HostProfile,
        service: any ExternalTerminalConnecting
    ) async -> Bool {
        let tool = host.dockerCommandPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DockerCommandPrefix.fallback
            : host.dockerCommandPrefix
        let command = """
        state=$(\(tool) inspect -f '{{.State.Status}}' terminator-helper 2>/dev/null || true)
        if [ "$state" != running ]; then exit 2; fi
        printf '%s\\n' '---TOKEN---'
        cat "${HOME:-/tmp}/.terminator-helper/token"
        printf '\\n%s\\n' '---CERT---'
        cat "${HOME:-/tmp}/.terminator-helper/cert.pem"
        """
        guard let result = try? await service.exec(host: host, command: command),
              result.exitCode == 0 else {
            return false
        }
        let text = result.stdout.replacingOccurrences(of: "\r", with: "")
        guard let tokenMarker = text.range(of: "---TOKEN---\n"),
              let certMarker = text.range(of: "\n---CERT---\n") else { return false }
        let token = text[tokenMarker.upperBound..<certMarker.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pem = String(text[certMarker.upperBound...])
        guard !token.isEmpty, let der = HelperCertificate.der(pem: pem), !der.isEmpty else {
            return false
        }
        let secretID = SecretID()
        do {
            try await secretStore.store(Data(token.utf8), for: secretID)
        } catch {
            return false
        }
        var installation = HelperInstallation(
            hostID: host.id,
            port: HelperSnapshot.port,
            tokenSecretID: secretID,
            certificateDER: der,
            localPort: HelperForward.localPort(for: host.id)
        )
        helperTokens[host.id] = token
        guard await poll(host: host, installation: installation, token: token) else {
            helperTokens[host.id] = nil
            try? await secretStore.purge(id: secretID)
            return false
        }
        do {
            try storeHelper(installation)
        } catch {
            helperTokens[host.id] = nil
            markHelperOffline(host.id)
            try? await secretStore.purge(id: secretID)
            return false
        }
        return true
    }



    private func markHelperOffline(_ hostID: UUID) {
        helperOnline.remove(hostID)
        helperStatuses[hostID] = nil
        helperContainers[hostID] = nil
    }

    private func applyHostStatuses() {
        var merged: [UUID: HostStatusSnapshot] = [:]
        for (id, snapshot) in serviceHostStatuses {
            switch connectionPhase(for: id) {
            case .connected, .agent, .reconnecting:
                merged[id] = snapshot
            default:
                break
            }
        }
        for id in helperOnline {
            guard let helper = helperStatuses[id] else { continue }
            if let service = merged[id] {
                merged[id] = helper.fillingGaps(from: service)
            } else {
                merged[id] = helper
            }
        }
        hostStatuses = merged
    }

    private func applyDockerInventory() {
        let covered = helperOnline
        var containers = serviceDockerContainers.filter { container in
            guard case .host(let id, _) = container.endpoint else { return true }
            return !covered.contains(id)
        }
        for id in covered {
            containers.append(contentsOf: helperContainers[id] ?? [])
        }
        dockerContainers = containers
        dockerUpdating = serviceDockerUpdating.filter { endpoint in
            guard case .host(let id, _) = endpoint else { return true }
            return !covered.contains(id)
        }
        dockerInventoryReady = serviceDockerReady || !helperOnline.isEmpty
    }

    private func hostIDs(in endpoints: [DockerEndpoint]) -> Set<UUID> {
        Set(endpoints.compactMap { endpoint in
            if case .host(let id, _) = endpoint { return id }
            return nil
        })
    }

    func dockerRuntime(_ container: DockerContainer) async -> DockerRuntimeStatus? {
        if case .host(let hostID, _) = container.endpoint, helperOnline.contains(hostID),
           let installation = helperInstallations.first(where: { $0.hostID == hostID }),
           let token = await token(for: installation),
           let host = hosts.first(where: { $0.id == hostID }) {
            let endpoint = (try? await reachableEndpoint(host: host, installation: installation))
                ?? (hostname: host.hostname, port: installation.port)
            if let text = try? await HelperPoll.runtime(
                hostname: endpoint.hostname,
                port: endpoint.port,
                token: token,
                certificateDER: installation.certificateDER,
                containerID: container.id
            ), let status = DockerRuntimeStatus.parse(text) {
                return status
            }
        }
        guard let tunnelController else { return nil }
        guard let text = try? await tunnelController.controlDocker(
            endpoint: container.endpoint,
            containerID: container.id,
            action: .stats
        ) else { return nil }
        return DockerRuntimeStatus.parse(text)
    }

    func dockerLogText(_ container: DockerContainer) async -> String {
        if case .host(let hostID, _) = container.endpoint, helperOnline.contains(hostID) {
            guard let installation = helperInstallations.first(where: { $0.hostID == hostID }),
                  let token = await token(for: installation),
                  let host = hosts.first(where: { $0.id == hostID }) else {
                return HelperInstallError.unavailable.localizedDescription
            }
            do {
                let endpoint = (try? await reachableEndpoint(host: host, installation: installation))
                    ?? (hostname: host.hostname, port: installation.port)
                return try await HelperPoll.control(
                    hostname: endpoint.hostname,
                    port: endpoint.port,
                    token: token,
                    certificateDER: installation.certificateDER,
                    containerID: container.id,
                    action: .logs
                )
            } catch {
                return error.localizedDescription
            }
        }
        guard let tunnelController else { return ConnectionServiceError.unavailable.localizedDescription }
        do {
            return try await tunnelController.controlDocker(
                endpoint: container.endpoint,
                containerID: container.id,
                action: .logs
            )
        } catch {
            return error.localizedDescription
        }
    }

    func runDockerThroughHelper(_ container: DockerContainer, action: DockerControlAction) async -> Bool {
        guard case .host(let hostID, _) = container.endpoint, helperOnline.contains(hostID) else { return false }
        if action == .stats { return false }
        guard let installation = helperInstallations.first(where: { $0.hostID == hostID }),
              let token = await token(for: installation),
              let host = hosts.first(where: { $0.id == hostID }) else {
            present(HelperInstallError.unavailable)
            return true
        }
        do {
            let endpoint = (try? await reachableEndpoint(host: host, installation: installation))
                ?? (hostname: host.hostname, port: installation.port)
            let text = try await HelperPoll.control(
                hostname: endpoint.hostname,
                port: endpoint.port,
                token: token,
                certificateDER: installation.certificateDER,
                containerID: container.id,
                action: action
            )
            if action == .logs {
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                dockerOutput = DockerCommandOutput(
                    title: "\(container.name) logs",
                    text: body.isEmpty ? "No logs." : body
                )
            } else {
                noteContainerChange(container, action: action)
            }
        } catch {
            present(error)
        }
        return true
    }

    private func noteContainerChange(_ container: DockerContainer, action: DockerControlAction) {
        let state: String?
        switch action {
        case .start, .unpause: state = "running"
        case .stop: state = "exited"
        case .pause: state = "paused"
        case .restart: state = "restarting"
        case .remove: state = nil
        case .logs, .stats: return
        }
        guard case .host(let hostID, _) = container.endpoint else { return }
        var items = helperContainers[hostID] ?? []
        if let state {
            items = items.map { item in
                guard item.id == container.id else { return item }
                var copy = item
                copy.state = state
                return copy
            }
        } else {
            items.removeAll { $0.id == container.id }
        }
        helperContainers[hostID] = items
        applyDockerInventory()
    }
}
