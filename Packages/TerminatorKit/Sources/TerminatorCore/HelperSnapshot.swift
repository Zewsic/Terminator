import Foundation

public enum HelperSnapshot {
    public static let port = 53621
    /// Bump when the bundled helper script changes. Older installations update to this.
    public static let version = "4"

    public static func reportedVersion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let version = object["version"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = object["version"] as? Int { return String(number) }
        return nil
    }

    public static func parse(_ data: Data, hostID: UUID, endpoint: DockerEndpoint, collectedAt: Date = .now) -> (HostStatusSnapshot, [DockerContainer])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let load = numberList(object["load"])
        let memoryObject = object["memory"] as? [String: Any] ?? [:]
        let memory = HostMemoryStatus(
            total: uint(memoryObject["total"]),
            used: uint(memoryObject["used"]),
            available: uint(memoryObject["available"]),
            swapTotal: uint(memoryObject["swapTotal"]),
            swapUsed: uint(memoryObject["swapUsed"]),
            cached: uint(memoryObject["cached"])
        )
        let cores = (object["cores"] as? [[String: Any]] ?? []).compactMap { item -> HostCPUCore? in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return HostCPUCore(name: name, usage: item["usage"] as? Double ?? 0)
        }
        let disks = (object["disks"] as? [[String: Any]] ?? []).compactMap { item -> HostDiskStatus? in
            guard let mount = item["mount"] as? String, !mount.isEmpty else { return nil }
            return HostDiskStatus(
                name: item["name"] as? String ?? mount,
                fileSystem: item["fileSystem"] as? String ?? "",
                mount: mount,
                total: uint(item["total"]),
                used: uint(item["used"]),
                readBytesPerSecond: double(item["read"]),
                writeBytesPerSecond: double(item["write"])
            )
        }
        let networkObject = object["network"] as? [String: Any] ?? [:]
        let interfaces = (networkObject["interfaces"] as? [[String: Any]] ?? []).compactMap { item -> HostNetworkInterface? in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return HostNetworkInterface(
                name: name,
                receiveBytesPerSecond: double(item["receive"]),
                transmitBytesPerSecond: double(item["transmit"])
            )
        }
        let processes = (object["processes"] as? [[String: Any]] ?? []).compactMap { item -> HostProcessStatus? in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return HostProcessStatus(
                pid: int(item["pid"]),
                user: item["user"] as? String ?? "",
                name: name,
                cpu: double(item["cpu"]),
                memory: uint(item["memory"]),
                readBytesPerSecond: double(item["read"]),
                writeBytesPerSecond: double(item["write"])
            )
        }
        let snapshot = HostStatusSnapshot(
            hostID: hostID,
            collectedAt: collectedAt,
            uptime: object["uptime"] as? TimeInterval ?? double(object["uptime"]),
            load1: load.count > 0 ? load[0] : 0,
            load5: load.count > 1 ? load[1] : 0,
            load15: load.count > 2 ? load[2] : 0,
            cores: cores,
            memory: memory,
            disks: disks,
            network: HostNetworkStatus(
                receiveBytesPerSecond: double(networkObject["receive"]),
                transmitBytesPerSecond: double(networkObject["transmit"]),
                interfaces: interfaces
            ),
            processes: processes
        )
        let containers = (object["containers"] as? [[String: Any]] ?? []).compactMap { item -> DockerContainer? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let labels = item["labels"] as? [String: String] ?? [:]
            var imageID = item["imageID"] as? String ?? ""
            if imageID.hasPrefix("sha256:") { imageID.removeFirst("sha256:".count) }
            imageID = String(imageID.prefix(12))
            return DockerInventory.makeContainer(
                id: id,
                name: item["name"] as? String ?? String(id.prefix(12)),
                image: item["image"] as? String ?? "",
                imageID: imageID,
                state: (item["state"] as? String ?? "").lowercased(),
                health: item["health"] as? String,
                labels: labels,
                endpoint: endpoint,
                builtLocally: item["local"] as? Bool ?? false,
                baseImage: {
                    let value = (item["baseImage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return value.isEmpty ? nil : value
                }(),
                ports: publishedPorts(item["ports"])
            )
        }
        return (snapshot, containers)
    }

    private static func numberList(_ value: Any?) -> [Double] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { item in
            if let number = item as? Double { return number }
            if let number = item as? Int { return Double(number) }
            return nil
        }
    }

    private static func double(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return 0
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func publishedPorts(_ value: Any?) -> [DockerPublishedPort] {
        guard let rows = value as? [[String: Any]] else { return [] }
        var ports: [DockerPublishedPort] = []
        for row in rows {
            let hostPort = int(row["hostPort"])
            let containerPort = int(row["containerPort"])
            guard hostPort > 0, containerPort > 0 else { continue }
            let ip = (row["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"
            let proto = (row["proto"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "tcp"
            let port = DockerPublishedPort(ip: ip, hostPort: hostPort, containerPort: containerPort, proto: proto)
            if !ports.contains(where: { $0.hostPort == port.hostPort && $0.containerPort == port.containerPort && $0.proto == port.proto }) {
                ports.append(port)
            }
        }
        return ports
    }

    private static func uint(_ value: Any?) -> UInt64 {
        if let number = value as? UInt64 { return number }
        if let number = value as? Int { return UInt64(max(0, number)) }
        if let number = value as? Double { return UInt64(max(0, number)) }
        return 0
    }
}

public enum HelperVersion {
    public static func isOlder(_ installed: String, than bundled: String) -> Bool {
        let left = components(installed)
        let right = components(bundled)
        if left.isEmpty || right.isEmpty { return installed != bundled }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs < rhs }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        let parts = version.split(separator: ".")
        guard !parts.isEmpty else { return [] }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return [] }
            values.append(value)
        }
        return values
    }
}
