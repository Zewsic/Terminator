import Foundation

public enum TunnelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case remote
    case dynamic

    public var displayName: String {
        switch self {
        case .local: TerminatorCoreLocalization.text(.tunnelKindLocal)
        case .remote: TerminatorCoreLocalization.text(.tunnelKindRemote)
        case .dynamic: TerminatorCoreLocalization.text(.tunnelKindDynamic)
        }
    }
}

public enum TunnelEndpoint: Codable, Hashable, Sendable {
    case thisMac
    case saved(UUID)
    case manual(id: UUID, hostname: String, port: Int)

    public var savedHostID: UUID? {
        if case .saved(let id) = self { return id }
        return nil
    }

    public var poolHostID: UUID? {
        switch self {
        case .thisMac: nil
        case .saved(let id): id
        case .manual(let id, _, _): id
        }
    }
}

public enum TunnelValidationError: LocalizedError, Equatable, Sendable {
    case missingDisplayName
    case invalidPort
    case destinationIsLocal
    case missingHostname
    case dynamicRequiresThisMac

    public var errorDescription: String? {
        switch self {
        case .missingDisplayName: TerminatorCoreLocalization.text(.errorTunnelMissingDisplayName)
        case .invalidPort: TerminatorCoreLocalization.text(.errorTunnelInvalidPort)
        case .destinationIsLocal: TerminatorCoreLocalization.text(.errorTunnelDestinationIsLocal)
        case .missingHostname: TerminatorCoreLocalization.text(.errorTunnelMissingHostname)
        case .dynamicRequiresThisMac: TerminatorCoreLocalization.text(.errorTunnelDynamicRequiresThisMac)
        }
    }
}

public struct TunnelProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var kind: TunnelKind
    public var source: TunnelEndpoint
    public var destination: TunnelEndpoint
    public var listenAddress: String
    public var listenPort: Int
    public var targetAddress: String
    public var targetPort: Int
    public var connectAutomatically: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        kind: TunnelKind = .local,
        source: TunnelEndpoint = .thisMac,
        destination: TunnelEndpoint,
        listenAddress: String = "127.0.0.1",
        listenPort: Int = 8_888,
        targetAddress: String = "127.0.0.1",
        targetPort: Int = 8_888,
        connectAutomatically: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.source = source
        self.destination = destination
        self.listenAddress = listenAddress
        self.listenPort = listenPort
        self.targetAddress = targetAddress
        self.targetPort = targetPort
        self.connectAutomatically = connectAutomatically
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }

    public func validated() throws -> TunnelProfile {
        var copy = self
        copy.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.listenAddress = listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.targetAddress = targetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.source = try copy.source.validated()
        copy.destination = try copy.destination.validated()
        guard !copy.displayName.isEmpty else { throw TunnelValidationError.missingDisplayName }
        if case .thisMac = copy.destination { throw TunnelValidationError.destinationIsLocal }
        guard (1...65_535).contains(copy.listenPort) else { throw TunnelValidationError.invalidPort }
        if copy.kind != .dynamic {
            guard (1...65_535).contains(copy.targetPort) else { throw TunnelValidationError.invalidPort }
            guard !copy.targetAddress.isEmpty else { throw TunnelValidationError.missingHostname }
        }
        guard !copy.listenAddress.isEmpty else { throw TunnelValidationError.missingHostname }
        if case .thisMac = copy.source {
        } else {
            copy.connectAutomatically = false
        }
        return copy
    }

    public func derivedTags(in hosts: [HostProfile]) -> [String] {
        var seen: Set<String> = []
        return [kind.displayName, endpointName(source, in: hosts, fallback: "Host A"), endpointName(destination, in: hosts, fallback: "Host B")]
            .filter { seen.insert($0).inserted }
    }

    public func groupName(in hosts: [HostProfile]) -> String? {
        guard let id = destination.savedHostID else { return nil }
        let group = hosts.first { $0.id == id }?.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return group.isEmpty ? nil : group
    }

    public func endpointName(_ endpoint: TunnelEndpoint, in hosts: [HostProfile], fallback: String) -> String {
        switch endpoint {
        case .thisMac:
            TerminatorCoreLocalization.text(.tunnelEndpointThisMac)
        case .saved(let id):
            hosts.first { $0.id == id }?.displayName ?? fallback
        case .manual(_, let hostname, _):
            hostname.isEmpty ? fallback : hostname
        }
    }

    public func usesPool(_ hostID: UUID) -> Bool {
        source.poolHostID == hostID || destination.poolHostID == hostID
    }

    public static func imported(
        from tunnel: ExternalImportTunnel,
        sshHost: ExternalImportHost?,
        savedHosts: [HostProfile],
        now: Date = .now
    ) -> TunnelProfile {
        let destination: TunnelEndpoint
        if let sshHost {
            let match = savedHosts.first {
                $0.hostname.caseInsensitiveCompare(sshHost.hostname) == .orderedSame && $0.port == sshHost.port
            }
            if let match {
                destination = .saved(match.id)
            } else {
                destination = .manual(id: UUID(), hostname: sshHost.hostname, port: max(sshHost.port, 1))
            }
        } else {
            destination = .manual(id: UUID(), hostname: tunnel.targetHost, port: 22)
        }
        let label = tunnel.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return TunnelProfile(
            displayName: label.isEmpty ? tunnel.kind.rawValue.capitalized : label,
            kind: TunnelKind(rawValue: tunnel.kind.rawValue) ?? .local,
            source: .thisMac,
            destination: destination,
            listenAddress: tunnel.bindAddress.isEmpty ? "127.0.0.1" : tunnel.bindAddress,
            listenPort: max(tunnel.localPort, 1),
            targetAddress: tunnel.targetHost.isEmpty ? "127.0.0.1" : tunnel.targetHost,
            targetPort: max(tunnel.targetPort, 1),
            connectAutomatically: false,
            createdAt: now,
            updatedAt: now
        )
    }
}

public enum TunnelForwardPlan: Equatable, Sendable {
    case listenLocally(address: String, port: Int, dial: Dial)
    case listenRemotely(listener: TunnelEndpoint, address: String, port: Int, dial: Dial)

    public enum Dial: Equatable, Sendable {
        case localAddress(String, Int)
        case through(TunnelEndpoint, address: String, port: Int)
        case socks(through: TunnelEndpoint)
    }

    public static func make(_ tunnel: TunnelProfile) throws -> TunnelForwardPlan {
        let tunnel = try tunnel.validated()
        switch tunnel.kind {
        case .local:
            let dial = Dial.through(tunnel.destination, address: tunnel.targetAddress, port: tunnel.targetPort)
            if case .thisMac = tunnel.source {
                return .listenLocally(address: tunnel.listenAddress, port: tunnel.listenPort, dial: dial)
            }
            return .listenRemotely(
                listener: tunnel.source, address: tunnel.listenAddress, port: tunnel.listenPort, dial: dial
            )
        case .remote:
            let dial: Dial
            if case .thisMac = tunnel.source {
                dial = .localAddress(tunnel.listenAddress, tunnel.listenPort)
            } else {
                dial = .through(tunnel.source, address: tunnel.listenAddress, port: tunnel.listenPort)
            }
            return .listenRemotely(
                listener: tunnel.destination, address: tunnel.targetAddress, port: tunnel.targetPort, dial: dial
            )
        case .dynamic:
            guard case .thisMac = tunnel.source else { throw TunnelValidationError.dynamicRequiresThisMac }
            return .listenLocally(
                address: tunnel.listenAddress, port: tunnel.listenPort, dial: .socks(through: tunnel.destination)
            )
        }
    }
}

extension TunnelEndpoint {
    fileprivate func validated() throws -> TunnelEndpoint {
        switch self {
        case .thisMac, .saved:
            return self
        case .manual(let id, let hostname, let port):
            let hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hostname.isEmpty else { throw TunnelValidationError.missingHostname }
            guard (1...65_535).contains(port) else { throw TunnelValidationError.invalidPort }
            return .manual(id: id, hostname: hostname, port: port)
        }
    }
}

public protocol SSHTunnelControlling: Sendable {
    func startTunnel(_ tunnel: TunnelProfile) async throws
    func stopTunnel(id: UUID) async
    func tunnelPhases() async -> AsyncStream<TunnelPhaseEvent>
    func dockerInventory() async -> AsyncStream<DockerInventorySnapshot>
    func hostStatuses() async -> AsyncStream<HostStatusSnapshot>
    func tunnelTraffic() async -> AsyncStream<TunnelTrafficSnapshot>
    func controlDocker(endpoint: DockerEndpoint, containerID: String, action: DockerControlAction) async throws -> String
    func openContainerShell(endpoint: DockerEndpoint, containerID: String) async throws
}

public struct TunnelPhaseEvent: Codable, Equatable, Sendable {
    public var id: UUID
    public var phase: SSHConnectionPhase

    public init(id: UUID, phase: SSHConnectionPhase) {
        self.id = id
        self.phase = phase
    }
}
