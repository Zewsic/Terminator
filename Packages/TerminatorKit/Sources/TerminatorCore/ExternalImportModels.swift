import Foundation

public enum ExternalImportSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case openSSH
    case termiusDirect
    case termiusAppStore
}

public struct ExternalImportSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String { kind.rawValue }
    public var kind: ExternalImportSourceKind
    public var displayName: String
    public var applicationURL: URL?

    public init(kind: ExternalImportSourceKind, displayName: String, applicationURL: URL? = nil) {
        self.kind = kind
        self.displayName = displayName
        self.applicationURL = applicationURL
    }
}

public struct ExternalImportAccessKey: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var privateKey: String
    public var publicKey: String
    public var passphrase: String

    public init(id: String, label: String, privateKey: String, publicKey: String = "", passphrase: String = "") {
        self.id = id
        self.label = label
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.passphrase = passphrase
    }
}

public struct ExternalImportIdentity: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var username: String
    public var password: String
    public var accessKeyIDs: [String]

    public init(id: String, label: String, username: String, password: String = "", accessKeyIDs: [String] = []) {
        self.id = id
        self.label = label
        self.username = username
        self.password = password
        self.accessKeyIDs = accessKeyIDs
    }
}

public struct ExternalImportProxy: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var password: String

    public init(id: String, kind: String, hostname: String, port: Int, username: String = "", password: String = "") {
        self.id = id
        self.kind = kind
        self.hostname = hostname
        self.port = port
        self.username = username
        self.password = password
    }
}

public enum ExternalImportTunnelKind: String, Codable, Hashable, Sendable {
    case local
    case remote
    case dynamic
}

public struct ExternalImportTunnel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var hostID: String?
    public var label: String
    public var kind: ExternalImportTunnelKind
    public var bindAddress: String
    public var localPort: Int
    public var targetHost: String
    public var targetPort: Int

    public init(
        id: String, hostID: String? = nil, label: String, kind: ExternalImportTunnelKind,
        bindAddress: String = "127.0.0.1", localPort: Int, targetHost: String = "", targetPort: Int = 0
    ) {
        self.id = id
        self.hostID = hostID
        self.label = label
        self.kind = kind
        self.bindAddress = bindAddress
        self.localPort = localPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }
}

public struct ExternalImportKnownHost: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var hostnames: String
    public var key: String
    public var marker: String
    public var comment: String

    public init(id: String, hostnames: String, key: String, marker: String = "", comment: String = "") {
        self.id = id
        self.hostnames = hostnames
        self.key = key
        self.marker = marker
        self.comment = comment
    }
}

public struct ExternalImportHost: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var hostname: String
    public var port: Int
    public var group: String
    public var tags: [String]
    public var identityID: String?
    public var accessKeyID: String?
    public var proxyID: String?
    public var tunnelIDs: [String]

    public init(
        id: String, label: String, hostname: String, port: Int = 22, group: String = "", tags: [String] = [],
        identityID: String? = nil, accessKeyID: String? = nil, proxyID: String? = nil, tunnelIDs: [String] = []
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.group = group
        self.tags = tags
        self.identityID = identityID
        self.accessKeyID = accessKeyID
        self.proxyID = proxyID
        self.tunnelIDs = tunnelIDs
    }
}

public struct ExternalImportBundle: Codable, Hashable, Sendable {
    public var source: ExternalImportSource
    public var hosts: [ExternalImportHost]
    public var identities: [ExternalImportIdentity]
    public var accessKeys: [ExternalImportAccessKey]
    public var tunnels: [ExternalImportTunnel]
    public var proxies: [ExternalImportProxy]
    public var knownHosts: [ExternalImportKnownHost]
    public var snippets: [ExternalImportSnippet]

    public init(
        source: ExternalImportSource, hosts: [ExternalImportHost] = [], identities: [ExternalImportIdentity] = [],
        accessKeys: [ExternalImportAccessKey] = [], tunnels: [ExternalImportTunnel] = [],
        proxies: [ExternalImportProxy] = [], knownHosts: [ExternalImportKnownHost] = [],
        snippets: [ExternalImportSnippet] = []
    ) {
        self.source = source
        self.hosts = hosts
        self.identities = identities
        self.accessKeys = accessKeys
        self.tunnels = tunnels
        self.proxies = proxies
        self.knownHosts = knownHosts
        self.snippets = snippets
    }
}

public protocol ExternalImportService: Sendable {
    func availableSources() async -> [ExternalImportSource]
    func scan(_ source: ExternalImportSource) async throws -> ExternalImportBundle
}
