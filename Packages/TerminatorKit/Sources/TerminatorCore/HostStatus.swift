import Foundation

public struct HostCPUCore: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var usage: Double

    public var id: String { name }

    public init(name: String, usage: Double) {
        self.name = name
        self.usage = usage
    }
}

public struct HostMemoryStatus: Codable, Equatable, Sendable {
    public var total: UInt64
    public var used: UInt64
    public var available: UInt64
    public var swapTotal: UInt64
    public var swapUsed: UInt64
    public var cached: UInt64

    public init(total: UInt64, used: UInt64, available: UInt64, swapTotal: UInt64, swapUsed: UInt64, cached: UInt64) {
        self.total = total
        self.used = used
        self.available = available
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
        self.cached = cached
    }
}

public struct HostDiskStatus: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var fileSystem: String
    public var mount: String
    public var total: UInt64
    public var used: UInt64
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double

    public var id: String { mount }

    public init(
        name: String,
        fileSystem: String,
        mount: String,
        total: UInt64,
        used: UInt64,
        readBytesPerSecond: Double,
        writeBytesPerSecond: Double
    ) {
        self.name = name
        self.fileSystem = fileSystem
        self.mount = mount
        self.total = total
        self.used = used
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

public struct HostNetworkInterface: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var receiveBytesPerSecond: Double
    public var transmitBytesPerSecond: Double

    public var id: String { name }

    public init(name: String, receiveBytesPerSecond: Double, transmitBytesPerSecond: Double) {
        self.name = name
        self.receiveBytesPerSecond = receiveBytesPerSecond
        self.transmitBytesPerSecond = transmitBytesPerSecond
    }
}

public struct HostNetworkStatus: Codable, Equatable, Sendable {
    public var receiveBytesPerSecond: Double
    public var transmitBytesPerSecond: Double
    public var interfaces: [HostNetworkInterface]

    public init(
        receiveBytesPerSecond: Double,
        transmitBytesPerSecond: Double,
        interfaces: [HostNetworkInterface] = []
    ) {
        self.receiveBytesPerSecond = receiveBytesPerSecond
        self.transmitBytesPerSecond = transmitBytesPerSecond
        self.interfaces = interfaces
    }
}

public struct HostProcessStatus: Codable, Equatable, Sendable, Identifiable {
    public var pid: Int
    public var user: String
    public var name: String
    public var cpu: Double
    public var memory: UInt64
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double

    public var id: Int { pid }

    public init(
        pid: Int,
        user: String,
        name: String,
        cpu: Double,
        memory: UInt64,
        readBytesPerSecond: Double,
        writeBytesPerSecond: Double
    ) {
        self.pid = pid
        self.user = user
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

public struct HostStatusSnapshot: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var collectedAt: Date
    public var uptime: TimeInterval
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var cores: [HostCPUCore]
    public var memory: HostMemoryStatus
    public var disks: [HostDiskStatus]
    public var network: HostNetworkStatus
    public var processes: [HostProcessStatus]

    public init(
        hostID: UUID,
        collectedAt: Date,
        uptime: TimeInterval,
        load1: Double,
        load5: Double,
        load15: Double,
        cores: [HostCPUCore],
        memory: HostMemoryStatus,
        disks: [HostDiskStatus],
        network: HostNetworkStatus,
        processes: [HostProcessStatus]
    ) {
        self.hostID = hostID
        self.collectedAt = collectedAt
        self.uptime = uptime
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.cores = cores
        self.memory = memory
        self.disks = disks
        self.network = network
        self.processes = processes
    }

    public var averageCPU: Double {
        let cores = cores.filter { $0.name != "cpu" }
        let source = cores.isEmpty ? self.cores : cores
        guard !source.isEmpty else { return 0 }
        return source.reduce(0) { $0 + $1.usage } / Double(source.count)
    }

    public func fillingGaps(from other: HostStatusSnapshot) -> HostStatusSnapshot {
        var copy = self
        let placeholderDisks = disks.isEmpty || disks.allSatisfy {
            $0.readBytesPerSecond == 0 && $0.writeBytesPerSecond == 0 && disks.count == 1
        }
        if placeholderDisks, !other.disks.isEmpty { copy.disks = other.disks }
        if copy.processes.isEmpty { copy.processes = other.processes }
        if copy.cores.isEmpty { copy.cores = other.cores }
        if copy.network.interfaces.isEmpty, !other.network.interfaces.isEmpty {
            copy.network = HostNetworkStatus(
                receiveBytesPerSecond: copy.network.receiveBytesPerSecond == 0
                    ? other.network.receiveBytesPerSecond
                    : copy.network.receiveBytesPerSecond,
                transmitBytesPerSecond: copy.network.transmitBytesPerSecond == 0
                    ? other.network.transmitBytesPerSecond
                    : copy.network.transmitBytesPerSecond,
                interfaces: other.network.interfaces
            )
        }
        return copy
    }
}

public enum HostStatusReport {
    public static func parse(_ text: String, hostID: UUID, collectedAt: Date = .now) -> HostStatusSnapshot? {
        var uptime: TimeInterval?
        var load = (0.0, 0.0, 0.0)
        var cores: [HostCPUCore] = []
        var memory: HostMemoryStatus?
        var disks: [HostDiskStatus] = []
        var rates: [String: (Double, Double)] = [:]
        var interfaces: [HostNetworkInterface] = []
        var network = HostNetworkStatus(receiveBytesPerSecond: 0, transmitBytesPerSecond: 0)
        var processes: [HostProcessStatus] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("DISK\t") || line.hasPrefix("PROC\t") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if fields.first == "DISK", fields.count >= 8 {
                    disks.append(
                        HostDiskStatus(
                            name: fields[1],
                            fileSystem: fields[2],
                            mount: fields.dropFirst(7).joined(separator: "\t"),
                            total: UInt64(fields[3]) ?? 0,
                            used: UInt64(fields[4]) ?? 0,
                            readBytesPerSecond: Double(fields[5]) ?? 0,
                            writeBytesPerSecond: Double(fields[6]) ?? 0
                        )
                    )
                } else if fields.first == "PROC", fields.count >= 8 {
                    processes.append(
                        HostProcessStatus(
                            pid: Int(fields[1]) ?? 0,
                            user: fields[6],
                            name: fields.dropFirst(7).joined(separator: "\t"),
                            cpu: (Double(fields[2]) ?? 0) / 100,
                            memory: UInt64(fields[3]) ?? 0,
                            readBytesPerSecond: Double(fields[4]) ?? 0,
                            writeBytesPerSecond: Double(fields[5]) ?? 0
                        )
                    )
                }
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let kind = fields.first else { continue }
            switch kind {
            case "UPTIME":
                uptime = TimeInterval(fields.dropFirst().first ?? "")
            case "LOAD" where fields.count >= 4:
                load = (Double(fields[1]) ?? 0, Double(fields[2]) ?? 0, Double(fields[3]) ?? 0)
            case "CORE" where fields.count >= 3:
                cores.append(HostCPUCore(name: fields[1], usage: (Double(fields[2]) ?? 0) / 100))
            case "MEM" where fields.count >= 7:
                memory = HostMemoryStatus(
                    total: UInt64(fields[1]) ?? 0,
                    used: UInt64(fields[2]) ?? 0,
                    available: UInt64(fields[3]) ?? 0,
                    swapTotal: UInt64(fields[4]) ?? 0,
                    swapUsed: UInt64(fields[5]) ?? 0,
                    cached: UInt64(fields[6]) ?? 0
                )
            case "SWAP" where fields.count >= 3:
                if let current = memory {
                    memory = HostMemoryStatus(
                        total: current.total,
                        used: current.used,
                        available: current.available,
                        swapTotal: UInt64(fields[1]) ?? 0,
                        swapUsed: UInt64(fields[2]) ?? 0,
                        cached: current.cached
                    )
                }
            case "DISKRATE" where fields.count >= 4:
                rates[fields[1]] = (Double(fields[2]) ?? 0, Double(fields[3]) ?? 0)
            case "NIC" where fields.count >= 4:
                interfaces.append(
                    HostNetworkInterface(
                        name: fields[1],
                        receiveBytesPerSecond: Double(fields[2]) ?? 0,
                        transmitBytesPerSecond: Double(fields[3]) ?? 0
                    )
                )
            case "NET" where fields.count >= 3:
                network = HostNetworkStatus(
                    receiveBytesPerSecond: Double(fields[1]) ?? 0,
                    transmitBytesPerSecond: Double(fields[2]) ?? 0
                )
            default:
                break
            }
        }
        guard let uptime, let memory else { return nil }
        if rates.isEmpty == false {
            disks = disks.map { disk in
                let key = disk.name.split(separator: "/").last.map(String.init) ?? disk.name
                guard let rate = rates[key] ?? rates[disk.name] else { return disk }
                return HostDiskStatus(
                    name: disk.name,
                    fileSystem: disk.fileSystem,
                    mount: disk.mount,
                    total: disk.total,
                    used: disk.used,
                    readBytesPerSecond: rate.0,
                    writeBytesPerSecond: rate.1
                )
            }
        }
        let perCore = cores.filter { $0.name != "cpu" }
        network = HostNetworkStatus(
            receiveBytesPerSecond: network.receiveBytesPerSecond,
            transmitBytesPerSecond: network.transmitBytesPerSecond,
            interfaces: interfaces
        )
        return HostStatusSnapshot(
            hostID: hostID,
            collectedAt: collectedAt,
            uptime: uptime,
            load1: load.0,
            load5: load.1,
            load15: load.2,
            cores: perCore.isEmpty ? cores : perCore,
            memory: memory,
            disks: disks,
            network: network,
            processes: processes
        )
    }
}

public struct TunnelTrafficSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var received: UInt64
    public var sent: UInt64
    public var startedAt: Date

    public init(id: UUID, received: UInt64, sent: UInt64, startedAt: Date) {
        self.id = id
        self.received = received
        self.sent = sent
        self.startedAt = startedAt
    }
}

public enum DockerControlAction: String, Codable, Sendable {
    case start
    case stop
    case pause
    case unpause
    case restart
    case remove
    case logs
    case stats
}

public enum DockerControl {
    public static func isSafeContainerID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9]{1,128}$"#, options: .regularExpression) != nil
    }

    public static func command(prefix: String, action: DockerControlAction, containerID: String) -> String? {
        guard isSafeContainerID(containerID) else { return nil }
        let tool = prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DockerCommandPrefix.fallback : prefix
        switch action {
        case .start, .stop, .pause, .unpause, .restart:
            return "\(tool) \(action.rawValue) \(containerID)"
        case .remove:
            return "\(tool) rm -f \(containerID)"
        case .logs:
            return "\(tool) logs --tail 200 --timestamps \(containerID)"
        case .stats:
            return """
            \(tool) inspect -s --format '{{json .}}' \(containerID)
            printf '\\n__TERMINATOR_SPLIT__\\n'
            \(tool) stats --no-stream --format '{{json .}}' \(containerID)
            """
        }
    }

    public static func shellCommand(prefix: String, containerID: String) -> String? {
        guard isSafeContainerID(containerID) else { return nil }
        let tool = prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DockerCommandPrefix.fallback : prefix
        return "\(tool) exec -it \(containerID) sh"
    }
}

public struct DockerRuntimeStatus: Equatable, Sendable {
    public var startedAt: Date?
    public var restartCount: Int
    public var ports: [String]
    public var published: [DockerPublishedPort]
    public var mounts: [String]
    public var cpu: Double?
    public var memoryUsed: UInt64?
    public var memoryLimit: UInt64?
    public var networkReceive: UInt64?
    public var networkTransmit: UInt64?
    public var blockRead: UInt64?
    public var blockWrite: UInt64?
    /// Writable layer from `docker inspect -s`. Not cumulative block I/O.
    public var diskUsed: UInt64?

    public static func parse(_ payload: String) -> DockerRuntimeStatus? {
        let parts = payload.components(separatedBy: "__TERMINATOR_SPLIT__")
        guard let inspectText = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = inspectText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let state = object["State"] as? [String: Any] ?? [:]
        let started = (state["StartedAt"] as? String).flatMap(parseDockerDate)
        let restarts = object["RestartCount"] as? Int ?? 0
        let published = DockerInventory.publishedPorts(from: object)
        var status = DockerRuntimeStatus(
            startedAt: started,
            restartCount: restarts,
            ports: published.map(\.binding),
            published: published,
            mounts: mounts(from: object),
            cpu: nil,
            memoryUsed: nil,
            memoryLimit: nil,
            networkReceive: nil,
            networkTransmit: nil,
            blockRead: nil,
            blockWrite: nil,
            diskUsed: (object["SizeRw"] as? NSNumber)?.uint64Value
        )
        if parts.count > 1,
           let statsData = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let stats = try? JSONSerialization.jsonObject(with: statsData) as? [String: Any] {
            status.cpu = percent(stats["CPUPerc"] as? String)
            let memory = pair(stats["MemUsage"] as? String)
            status.memoryUsed = memory?.0
            status.memoryLimit = memory?.1
            let network = pair(stats["NetIO"] as? String)
            status.networkReceive = network?.0
            status.networkTransmit = network?.1
            let block = pair(stats["BlockIO"] as? String)
            status.blockRead = block?.0
            status.blockWrite = block?.1
        }
        return status
    }

    private static func mounts(from object: [String: Any]) -> [String] {
        let mounts = object["Mounts"] as? [[String: Any]] ?? []
        return mounts.compactMap { mount in
            guard let destination = mount["Destination"] as? String, !destination.isEmpty else { return nil }
            let source = mount["Source"] as? String ?? ""
            return source.isEmpty ? destination : "\(source) → \(destination)"
        }
    }

    private static func percent(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let number = raw.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        return Double(number).map { $0 / 100 }
    }

    private static func pair(_ raw: String?) -> (UInt64, UInt64)? {
        guard let raw else { return nil }
        let sides = raw.components(separatedBy: "/")
        guard sides.count == 2, let left = bytes(sides[0]), let right = bytes(sides[1]) else { return nil }
        return (left, right)
    }

    private static func bytes(_ raw: String) -> UInt64? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let suffix = text.drop { $0.isNumber || $0 == "." }
        let number = text.dropLast(suffix.count)
        guard let value = Double(number) else { return nil }
        let scale: Double
        switch suffix.lowercased() {
        case "b", "": scale = 1
        case "kb": scale = 1_000
        case "mb": scale = 1_000_000
        case "gb": scale = 1_000_000_000
        case "tb": scale = 1_000_000_000_000
        case "kib": scale = 1024
        case "mib": scale = 1024 * 1024
        case "gib": scale = 1024 * 1024 * 1024
        case "tib": scale = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return UInt64(value * scale)
    }

    private static func parseDockerDate(_ raw: String) -> Date? {
        let trimmed = raw.split(separator: ".").first.map(String.init) ?? raw
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: trimmed.hasSuffix("Z") ? trimmed : trimmed + "Z") { return date }
        return formatter.date(from: raw)
    }
}
