import Foundation
import TerminatorCore

extension TerminatorAppModel {
    public func tunnelPhase(for id: UUID) -> SSHConnectionPhase {
        tunnelPhases[id] ?? .disconnected
    }

    public func saveTunnel(_ draft: TunnelDraft) async -> Bool {
        guard let tunnelRepository else {
            present(id: "tunnel.repository", message: FeatureL10n.text(.tunnelUnavailable))
            return false
        }
        do {
            let existing = draft.id.flatMap { id in tunnels.first { $0.id == id } }
            let now = Date.now
            guard let destination = draft.destination else { throw TunnelValidationError.missingHostname }
            let tunnel = try TunnelProfile(
                id: existing?.id ?? draft.id ?? UUID(),
                displayName: draft.displayName,
                kind: draft.kind,
                source: draft.source,
                destination: destination,
                listenAddress: draft.listenAddress,
                listenPort: draft.listenPort,
                targetAddress: draft.targetAddress,
                targetPort: draft.targetPort,
                connectAutomatically: draft.connectAutomatically,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                deletedAt: existing?.deletedAt
            ).validated()
            try await tunnelRepository.saveTunnel(tunnel)
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func deleteTunnel(id: UUID) async {
        guard let tunnelRepository else { return }
        await stopTunnel(id: id)
        do {
            try await tunnelRepository.deleteTunnel(id: id)
            tunnelPhases[id] = nil
            ArchiveHintStore.shared.arm()
            await load()
        } catch { present(error) }
    }

    public func restoreTunnel(id: UUID) async -> Bool {
        guard let tunnelRepository else { return false }
        do {
            try await tunnelRepository.restoreTunnel(id: id)
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func purgeTunnel(id: UUID) async -> Bool {
        guard let tunnelRepository else { return false }
        await stopTunnel(id: id)
        do {
            try await tunnelRepository.purgeTunnel(id: id)
            tunnelPhases[id] = nil
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func startTunnel(id: UUID) async {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else { return }
        guard let tunnelController else {
            present(id: "tunnel.controller", message: FeatureL10n.text(.tunnelUnavailable))
            return
        }
        if case .dynamic = tunnel.kind, case .thisMac = tunnel.source {
        } else if case .dynamic = tunnel.kind {
            present(TunnelValidationError.dynamicRequiresThisMac)
            return
        }
        tunnelPhases[id] = .authenticating
        do {
            try await tunnelController.startTunnel(tunnel)
            if tunnelPhases[id]?.isFailure != true { tunnelPhases[id] = .connected }
        } catch {
            tunnelPhases[id] = .failed(message: error.localizedDescription)
            present(error)
        }
    }

    public func stopTunnel(id: UUID) async {
        await tunnelController?.stopTunnel(id: id)
        tunnelPhases[id] = .disconnected
    }

    public func startAutomaticTunnels(for hostID: UUID) async {
        for tunnel in tunnels where tunnel.connectAutomatically && tunnel.destination.savedHostID == hostID {
            if case .connected = tunnelPhase(for: tunnel.id) { continue }
            if tunnelPhase(for: tunnel.id).isWorking { continue }
            await startTunnel(id: tunnel.id)
        }
    }

    public func importExternalTunnel(_ tunnel: ExternalImportTunnel, from bundle: ExternalImportBundle) async -> Bool {
        let sshHost = tunnel.hostID.flatMap { id in bundle.hosts.first { $0.id == id } }
        let profile = TunnelProfile.imported(from: tunnel, sshHost: sshHost, savedHosts: hosts)
        var draft = TunnelDraft(tunnel: profile)
        draft.id = nil
        let saved = await saveTunnel(draft)
        if saved { consumeExternalTunnel(tunnel, sourceID: bundle.source.id) }
        return saved
    }

    private func consumeExternalTunnel(_ tunnel: ExternalImportTunnel, sourceID: String) {
        guard var bundle = externalImportBundles[sourceID] else { return }
        bundle.tunnels.removeAll { $0.id == tunnel.id }
        externalImportBundles[sourceID] = bundle
    }
}

public struct TunnelDraft: Equatable, Sendable {
    var id: UUID?
    var displayName: String
    var kind: TunnelKind
    var source: TunnelEndpoint
    var destination: TunnelEndpoint?
    var listenAddress: String
    var listenPort: Int
    var targetAddress: String
    var targetPort: Int
    var connectAutomatically: Bool

    init(tunnel: TunnelProfile? = nil) {
        if let tunnel {
            id = tunnel.id
            displayName = tunnel.displayName
            kind = tunnel.kind
            source = tunnel.source
            destination = tunnel.destination
            listenAddress = tunnel.listenAddress
            listenPort = tunnel.listenPort
            targetAddress = tunnel.targetAddress
            targetPort = tunnel.targetPort
            connectAutomatically = tunnel.connectAutomatically
        } else {
            id = nil
            displayName = ""
            kind = .local
            source = .thisMac
            destination = nil
            listenAddress = "127.0.0.1"
            listenPort = 8_888
            targetAddress = "127.0.0.1"
            targetPort = 8_888
            connectAutomatically = false
        }
    }

    var allowsAutomaticConnect: Bool {
        if case .thisMac = source { return true }
        return false
    }
}
