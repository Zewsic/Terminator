import Foundation

public struct DockerPublishedPort: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var ip: String
    public var hostPort: Int
    public var containerPort: Int
    public var proto: String

    public var id: String { "\(ip):\(hostPort)->\(containerPort)/\(proto)" }

    public init(ip: String, hostPort: Int, containerPort: Int, proto: String) {
        self.ip = ip
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }

    public var binding: String {
        let host = ip.isEmpty || ip == "0.0.0.0" || ip == "::" ? "\(hostPort)" : "\(ip):\(hostPort)"
        return "\(host) → \(containerPort)/\(proto)"
    }

    /// Address the host itself can use to reach the published port.
    public var tunnelTargetAddress: String {
        if ip.isEmpty || ip == "0.0.0.0" || ip == "::" || ip == ":::" { return "127.0.0.1" }
        return ip
    }

    public static func parse(_ raw: String) -> [DockerPublishedPort] {
        var ports: [DockerPublishedPort] = []
        for part in raw.split(separator: ",") {
            guard let port = one(String(part)) else { continue }
            if !ports.contains(where: { $0.hostPort == port.hostPort && $0.containerPort == port.containerPort && $0.proto == port.proto }) {
                ports.append(port)
            } else if let index = ports.firstIndex(where: { $0.hostPort == port.hostPort && $0.containerPort == port.containerPort && $0.proto == port.proto }),
                      ports[index].ip == "::", port.ip != "::" {
                ports[index] = port
            }
        }
        return ports
    }

    private static func one(_ raw: String) -> DockerPublishedPort? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let arrow = text.range(of: "->") else { return nil }
        let left = String(text[..<arrow.lowerBound])
        let right = String(text[arrow.upperBound...])
        let protoSplit = right.split(separator: "/", omittingEmptySubsequences: false)
        guard let containerPort = Int(protoSplit.first ?? ""), containerPort > 0 else { return nil }
        let proto = protoSplit.count > 1 ? String(protoSplit[1]) : "tcp"
        let host: String
        let ip: String
        if left.hasPrefix("[") {
            guard let end = left.lastIndex(of: "]") else { return nil }
            ip = String(left[left.index(after: left.startIndex)..<end])
            host = String(left[left.index(after: end)...]).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        } else {
            let bits = left.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let last = bits.last else { return nil }
            host = last
            ip = bits.dropLast().joined(separator: ":")
        }
        guard let hostPort = Int(host), hostPort > 0 else { return nil }
        let normalized = ip == ":" || ip == ":::" ? "::" : ip
        return DockerPublishedPort(ip: normalized, hostPort: hostPort, containerPort: containerPort, proto: proto)
    }
}

public struct DockerContainer: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    public var imageID: String
    public var state: String
    public var health: String?
    public var endpoint: DockerEndpoint
    public var placement: DockerPlacement
    public var builtLocally: Bool
    public var baseImage: String?
    public var ports: [DockerPublishedPort]

    public init(
        id: String,
        name: String,
        image: String,
        imageID: String,
        state: String,
        health: String?,
        endpoint: DockerEndpoint,
        placement: DockerPlacement,
        builtLocally: Bool = false,
        baseImage: String? = nil,
        ports: [DockerPublishedPort] = []
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.imageID = imageID
        self.state = state
        self.health = health
        self.endpoint = endpoint
        self.placement = placement
        self.builtLocally = builtLocally
        self.baseImage = baseImage
        self.ports = ports
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, image, imageID, state, health, endpoint, placement, builtLocally, baseImage, ports
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        image = try container.decode(String.self, forKey: .image)
        imageID = try container.decode(String.self, forKey: .imageID)
        state = try container.decode(String.self, forKey: .state)
        health = try container.decodeIfPresent(String.self, forKey: .health)
        endpoint = try container.decode(DockerEndpoint.self, forKey: .endpoint)
        placement = try container.decode(DockerPlacement.self, forKey: .placement)
        builtLocally = try container.decodeIfPresent(Bool.self, forKey: .builtLocally) ?? false
        baseImage = try container.decodeIfPresent(String.self, forKey: .baseImage)
        ports = try container.decodeIfPresent([DockerPublishedPort].self, forKey: .ports) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(image, forKey: .image)
        try container.encode(imageID, forKey: .imageID)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(health, forKey: .health)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(placement, forKey: .placement)
        try container.encode(builtLocally, forKey: .builtLocally)
        try container.encodeIfPresent(baseImage, forKey: .baseImage)
        try container.encode(ports, forKey: .ports)
    }
}

public enum DockerEndpoint: Codable, Equatable, Hashable, Sendable {
    case mac
    case host(id: UUID, name: String)

    public var cacheKey: String {
        switch self {
        case .mac: "mac"
        case .host(let id, _): id.uuidString
        }
    }
}

public enum DockerPlacement: Codable, Equatable, Hashable, Sendable {
    case compose(project: String, hostID: UUID, hostName: String)
    case swarm(name: String)
    case host(id: UUID, name: String)
    case mac
}

public struct DockerSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var placement: DockerPlacement
    public var containers: [DockerContainer]

    public init(id: String, placement: DockerPlacement, containers: [DockerContainer]) {
        self.id = id
        self.placement = placement
        self.containers = containers
    }
}

public struct DockerInventorySnapshot: Codable, Equatable, Sendable {
    public var containers: [DockerContainer]
    public var updating: [DockerEndpoint]
    public var failed: [DockerEndpoint]

    public init(
        containers: [DockerContainer] = [],
        updating: [DockerEndpoint] = [],
        failed: [DockerEndpoint] = []
    ) {
        self.containers = containers
        self.updating = updating
        self.failed = failed
    }

    private enum CodingKeys: String, CodingKey {
        case containers, updating, failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        containers = try container.decodeIfPresent([DockerContainer].self, forKey: .containers) ?? []
        updating = try container.decodeIfPresent([DockerEndpoint].self, forKey: .updating) ?? []
        failed = try container.decodeIfPresent([DockerEndpoint].self, forKey: .failed) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(containers, forKey: .containers)
        try container.encode(updating, forKey: .updating)
        try container.encode(failed, forKey: .failed)
    }
}

public enum DockerCommandPrefix {
    public static let fallback = "docker"
    private static let pattern = #"^[A-Za-z0-9_./:-]+( [A-Za-z0-9_./:-]+)*$"#

    public static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        guard trimmed.count <= 128, trimmed.range(of: pattern, options: .regularExpression) != nil else {
            throw HostValidationError.invalidDockerCommandPrefix
        }
        return trimmed
    }
}

public enum DockerInventory {
    /// Stable id for a Compose project running on this Mac. Not a saved host.
    public static let localComposeHostID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public static func parseInspect(_ payload: String, endpoint: DockerEndpoint) -> [DockerContainer] {
        payload.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
            return container(from: data, endpoint: endpoint)
        }
    }

    /// Tab-separated `docker ps`: id, name, image, state, status, labels.
    public static func parseList(_ payload: String, endpoint: DockerEndpoint) -> [DockerContainer] {
        payload.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, !fields[0].isEmpty else { return nil }
            let name = fields[1].split(separator: ",").first.map(String.init) ?? fields[1]
            let status = fields[4].lowercased()
            let labels = labelList(fields[5])
            var imageID = labels["com.docker.compose.image"] ?? ""
            if imageID.hasPrefix("sha256:") { imageID.removeFirst("sha256:".count) }
            imageID = String(imageID.prefix(12))
            let health: String? = status.contains("unhealthy") ? "unhealthy" : (status.contains("healthy") ? "healthy" : nil)
            return DockerContainer(
                id: fields[0],
                name: name.isEmpty ? String(fields[0].prefix(12)) : name,
                image: fields[2],
                imageID: imageID,
                state: fields[3].lowercased(),
                health: health,
                endpoint: endpoint,
                placement: placement(labels: labels, endpoint: endpoint),
                ports: fields.count >= 7 ? DockerPublishedPort.parse(fields[6]) : []
            )
        }
    }

    public static func sections(_ containers: [DockerContainer]) -> [DockerSection] {
        let grouped = Dictionary(grouping: containers, by: \.placement)
        func sorted(_ items: [DockerContainer]) -> [DockerContainer] {
            items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        var compose: [(DockerPlacement, [DockerContainer])] = []
        var swarm: [(DockerPlacement, [DockerContainer])] = []
        var hosts: [(DockerPlacement, [DockerContainer])] = []
        var mac: [(DockerPlacement, [DockerContainer])] = []
        for (placement, items) in grouped where !items.isEmpty {
            let entry = (placement, sorted(items))
            switch placement {
            case .compose: compose.append(entry)
            case .swarm: swarm.append(entry)
            case .host: hosts.append(entry)
            case .mac: mac.append(entry)
            }
        }
        compose.sort { sectionTitle($0.0).localizedCaseInsensitiveCompare(sectionTitle($1.0)) == .orderedAscending }
        swarm.sort { sectionTitle($0.0).localizedCaseInsensitiveCompare(sectionTitle($1.0)) == .orderedAscending }
        hosts.sort { sectionTitle($0.0).localizedCaseInsensitiveCompare(sectionTitle($1.0)) == .orderedAscending }
        return (compose + swarm + hosts + mac).map { placement, items in
            DockerSection(id: sectionID(placement), placement: placement, containers: items)
        }
    }

    public static func sectionID(_ placement: DockerPlacement) -> String {
        switch placement {
        case .compose(let project, let hostID, _): "compose:\(project):\(hostID.uuidString)"
        case .swarm(let name): "swarm:\(name)"
        case .host(let id, _): "host:\(id.uuidString)"
        case .mac: "mac"
        }
    }

    public static func sectionTitle(_ placement: DockerPlacement) -> String {
        switch placement {
        case .compose(let project, _, let hostName): hostName.isEmpty ? project : "\(project) · \(hostName)"
        case .swarm(let name): name
        case .host(_, let name): name
        case .mac: ""
        }
    }

    private static func container(from data: Data, endpoint: DockerEndpoint) -> DockerContainer? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["Id"] as? String,
              !rawID.isEmpty else { return nil }
        let rawName = object["Name"] as? String ?? ""
        let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        let config = object["Config"] as? [String: Any] ?? [:]
        let image = config["Image"] as? String ?? ""
        var imageID = object["Image"] as? String ?? ""
        if imageID.hasPrefix("sha256:") { imageID.removeFirst("sha256:".count) }
        imageID = String(imageID.prefix(12))
        let stateObject = object["State"] as? [String: Any] ?? [:]
        let state = (stateObject["Status"] as? String ?? "").lowercased()
        let health = (stateObject["Health"] as? [String: Any])?["Status"] as? String
        let placement = placement(labels: stringMap(config["Labels"]), endpoint: endpoint)
        return DockerContainer(
            id: rawID,
            name: name,
            image: image,
            imageID: imageID,
            state: state,
            health: health,
            endpoint: endpoint,
            placement: placement,
            ports: publishedPorts(from: object)
        )
    }

    public static func makeContainer(
        id: String,
        name: String,
        image: String,
        imageID: String,
        state: String,
        health: String?,
        labels: [String: String],
        endpoint: DockerEndpoint,
        builtLocally: Bool = false,
        baseImage: String? = nil,
        ports: [DockerPublishedPort] = []
    ) -> DockerContainer {
        DockerContainer(
            id: id,
            name: name,
            image: image,
            imageID: imageID,
            state: state,
            health: health,
            endpoint: endpoint,
            placement: placement(labels: labels, endpoint: endpoint),
            builtLocally: builtLocally,
            baseImage: baseImage,
            ports: ports
        )
    }

    public static func publishedPorts(from object: [String: Any]) -> [DockerPublishedPort] {
        let network = object["NetworkSettings"] as? [String: Any]
        let ports = network?["Ports"] as? [String: Any] ?? [:]
        var result: [DockerPublishedPort] = []
        for (key, value) in ports {
            let bits = key.split(separator: "/")
            guard let containerPort = Int(bits.first ?? ""), containerPort > 0 else { continue }
            let proto = bits.count > 1 ? String(bits[1]) : "tcp"
            guard let bindings = value as? [[String: Any]] else { continue }
            for binding in bindings {
                guard let host = binding["HostPort"] as? String, let hostPort = Int(host), hostPort > 0 else { continue }
                let ip = (binding["HostIp"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"
                let port = DockerPublishedPort(ip: ip, hostPort: hostPort, containerPort: containerPort, proto: proto)
                if !result.contains(where: { $0.hostPort == port.hostPort && $0.containerPort == port.containerPort && $0.proto == port.proto }) {
                    result.append(port)
                }
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.containerPort != rhs.containerPort { return lhs.containerPort < rhs.containerPort }
            return lhs.hostPort < rhs.hostPort
        }
    }

    private static func labelList(_ raw: String) -> [String: String] {
        var labels: [String: String] = [:]
        for part in raw.split(separator: ",", omittingEmptySubsequences: true) {
            guard let separator = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<separator])
            guard !key.isEmpty, !key.contains(" ") else { continue }
            labels[key] = String(part[part.index(after: separator)...])
        }
        return labels
    }

    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any] else { return [:] }
        var labels: [String: String] = [:]
        for (key, item) in raw {
            if let item = item as? String { labels[key] = item }
        }
        return labels
    }

    private static func placement(labels: [String: String], endpoint: DockerEndpoint) -> DockerPlacement {
        if let stack = labels["com.docker.stack.namespace"], !stack.isEmpty {
            return .swarm(name: stack)
        }
        if let project = labels["com.docker.compose.project"], !project.isEmpty {
            switch endpoint {
            case .mac:
                return .compose(project: project, hostID: localComposeHostID, hostName: "")
            case .host(let id, let name):
                return .compose(project: project, hostID: id, hostName: name)
            }
        }
        switch endpoint {
        case .mac:
            return .mac
        case .host(let id, let name):
            return .host(id: id, name: name)
        }
    }

    public static func browserGroups(_ containers: [DockerContainer], macTitle: String) -> [DockerBrowserGroup] {
        var swarm: [String: [DockerContainer]] = [:]
        var hosts: [String: HostBucket] = [:]
        for container in containers {
            switch container.placement {
            case .swarm(let name):
                swarm[name, default: []].append(container)
            case .compose(let project, let hostID, let hostName):
                let key = hostKey(id: hostID, name: hostName, macTitle: macTitle)
                var bucket = hosts[key.id] ?? HostBucket(title: key.title)
                bucket.title = key.title
                bucket.compose[project, default: []].append(container)
                hosts[key.id] = bucket
            case .host(let id, let name):
                let key = hostKey(id: id, name: name, macTitle: macTitle)
                var bucket = hosts[key.id] ?? HostBucket(title: key.title)
                bucket.title = key.title
                bucket.loose.append(container)
                hosts[key.id] = bucket
            case .mac:
                let key = hostKey(id: localComposeHostID, name: "", macTitle: macTitle)
                var bucket = hosts[key.id] ?? HostBucket(title: key.title)
                bucket.title = key.title
                bucket.loose.append(container)
                hosts[key.id] = bucket
            }
        }
        var groups = swarm.keys.sorted(by: compare).map { name in
            DockerBrowserGroup(
                id: "swarm:\(name)",
                title: "SWARM: \(name)",
                sections: [DockerBrowserSection(id: "swarm:\(name)", title: nil, containers: sorted(swarm[name] ?? []))]
            )
        }
        let hostGroups = hosts.keys.sorted { compare(hosts[$0]?.title ?? "", hosts[$1]?.title ?? "") }.map { id in
            let bucket = hosts[id] ?? HostBucket(title: id)
            var sections = bucket.compose.keys.sorted(by: compare).map { project in
                DockerBrowserSection(
                    id: "compose:\(project):\(id)",
                    title: project,
                    containers: sorted(bucket.compose[project] ?? [])
                )
            }
            if !bucket.loose.isEmpty {
                sections.append(DockerBrowserSection(id: "other:\(id)", title: nil, containers: sorted(bucket.loose)))
            }
            return DockerBrowserGroup(id: id == "mac" ? "mac" : "host:\(id)", title: bucket.title, sections: sections)
        }
        groups.append(contentsOf: hostGroups)
        return groups
    }

    public static func baseImage(from createdBy: [String]) -> String? {
        for line in createdBy {
            guard let image = fromInstruction(line) else { continue }
            if image.lowercased() == "scratch" { continue }
            return image
        }
        return nil
    }

    public static func parsePoll(_ payload: String, endpoint: DockerEndpoint) -> [DockerContainer] {
        let parts = payload.components(separatedBy: "\n---FACTS---\n")
        let containers = parseList(parts[0], endpoint: endpoint)
        guard parts.count > 1 else { return containers }
        var facts: [String: (Bool, String?)] = [:]
        for line in parts[1].split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let image = fields.first, !image.isEmpty, fields.count >= 2 else { continue }
            let history = fields.count > 2 ? fields[2].split(separator: "\u{1e}").map(String.init) : []
            facts[image] = (fields[1] == "local", baseImage(from: history))
        }
        return containers.map { container in
            guard let fact = facts[container.image] else { return container }
            var copy = container
            copy.builtLocally = fact.0
            copy.baseImage = fact.1
            return copy
        }
    }

    private struct HostBucket {
        var title: String
        var compose: [String: [DockerContainer]] = [:]
        var loose: [DockerContainer] = []
    }

    private static func hostKey(id: UUID, name: String, macTitle: String) -> (id: String, title: String) {
        if id == localComposeHostID { return ("mac", macTitle) }
        return (id.uuidString, name)
    }

    private static func sorted(_ containers: [DockerContainer]) -> [DockerContainer] {
        containers.sorted { compare($0.name, $1.name) }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private static func fromInstruction(_ line: String) -> String? {
        let marker = "FROM "
        guard let range = line.range(of: marker) else { return nil }
        let prefix = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard prefix.isEmpty || prefix.hasSuffix("#(nop)") || prefix.hasSuffix("nop)") else { return nil }
        var image = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if let space = image.firstIndex(of: " ") { image = String(image[..<space]) }
        if let digest = image.firstIndex(of: "@") { image = String(image[..<digest]) }
        return image.isEmpty ? nil : image
    }

}

public struct DockerBrowserGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var sections: [DockerBrowserSection]

    public init(id: String, title: String, sections: [DockerBrowserSection]) {
        self.id = id
        self.title = title
        self.sections = sections
    }
}

public struct DockerBrowserSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var containers: [DockerContainer]

    public init(id: String, title: String?, containers: [DockerContainer]) {
        self.id = id
        self.title = title
        self.containers = containers
    }
}


public enum DockerHubRepository {
    /// `namespace/name` on Docker Hub, or nil when the reference is not a Hub image.
    public static func id(from image: String) -> String? {
        var reference = image.trimmingCharacters(in: .whitespacesAndNewlines)
        if reference.isEmpty { return nil }
        if let digest = reference.firstIndex(of: "@") { reference = String(reference[..<digest]) }
        var parts = reference.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }
        if parts.count > 1, first == "localhost" || first.contains(".") || first.contains(":") {
            let host = first.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
            guard host == "docker.io" || host == "index.docker.io" || host == "registry-1.docker.io" else { return nil }
            parts.removeFirst()
            guard parts.first?.isEmpty == false else { return nil }
        }
        if parts.count == 1 {
            let name = stripTag(parts[0])
            guard !name.isEmpty else { return nil }
            return "library/\(name.lowercased())"
        }
        guard parts.count == 2 else { return nil }
        let namespace = parts[0].lowercased()
        let name = stripTag(parts[1]).lowercased()
        guard !namespace.isEmpty, !name.isEmpty else { return nil }
        return "\(namespace)/\(name)"
    }

    private static func stripTag(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return name }
        return String(name[..<colon])
    }
}
