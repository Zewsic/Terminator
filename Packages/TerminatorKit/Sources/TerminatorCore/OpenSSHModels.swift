import Foundation

public enum OpenSSHDiscoveryStatus: String, Codable, Sendable {
    case available
    case existing
    case changed
    case unsupported
}

public struct DiscoveredAccessKey: Identifiable, Equatable, Sendable {
    public var id: String { privateKeyURL.path }
    public var label: String
    public var privateKeyURL: URL
    public var publicKeyURL: URL?
    public var privateKey: String
    public var publicKey: String
    public var fingerprint: String?
    public var isEncrypted: Bool
    public var status: OpenSSHDiscoveryStatus

    public init(
        label: String, privateKeyURL: URL, publicKeyURL: URL? = nil,
        privateKey: String, publicKey: String = "", fingerprint: String? = nil,
        isEncrypted: Bool = false, status: OpenSSHDiscoveryStatus = .available
    ) {
        self.label = label; self.privateKeyURL = privateKeyURL; self.publicKeyURL = publicKeyURL
        self.privateKey = privateKey; self.publicKey = publicKey; self.fingerprint = fingerprint
        self.isEncrypted = isEncrypted; self.status = status
    }
}

public struct DiscoveredSSHHost: Identifiable, Equatable, Sendable {
    public var id: String { "\(sourceURL.path)#\(alias)" }
    public var alias: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var identityFiles: [URL]
    public var sourceURL: URL
    public var status: OpenSSHDiscoveryStatus

    public init(
        alias: String, hostname: String, port: Int = 22, username: String,
        identityFiles: [URL] = [], sourceURL: URL,
        status: OpenSSHDiscoveryStatus = .available
    ) {
        self.alias = alias; self.hostname = hostname; self.port = port; self.username = username
        self.identityFiles = identityFiles; self.sourceURL = sourceURL; self.status = status
    }

    public var endpoint: String { port == 22 ? hostname : "[\(hostname)]:\(port)" }
}

public struct DiscoveredKnownHost: Identifiable, Equatable, Sendable {
    public var id: String { "\(endpoint)#\(algorithm)#\(fingerprint)" }
    public var endpoint: String
    public var algorithm: String
    public var publicKey: Data
    public var fingerprint: String
    public var sourceURL: URL
    public var status: OpenSSHDiscoveryStatus

    public init(
        endpoint: String, algorithm: String, publicKey: Data, fingerprint: String,
        sourceURL: URL, status: OpenSSHDiscoveryStatus = .available
    ) {
        self.endpoint = endpoint; self.algorithm = algorithm; self.publicKey = publicKey
        self.fingerprint = fingerprint; self.sourceURL = sourceURL; self.status = status
    }
}

public struct OpenSSHScanDiagnostics: Equatable, Sendable {
    public var ignoredFiles: Int
    public var malformedLines: Int
    public var unsupportedEntries: Int
    public var messages: [String]

    public init(ignoredFiles: Int = 0, malformedLines: Int = 0, unsupportedEntries: Int = 0, messages: [String] = []) {
        self.ignoredFiles = ignoredFiles; self.malformedLines = malformedLines
        self.unsupportedEntries = unsupportedEntries; self.messages = messages
    }
}

public struct OpenSSHDiscoverySnapshot: Equatable, Sendable {
    public var hosts: [DiscoveredSSHHost]
    public var accessKeys: [DiscoveredAccessKey]
    public var knownHosts: [DiscoveredKnownHost]
    public var diagnostics: OpenSSHScanDiagnostics

    public init(
        hosts: [DiscoveredSSHHost] = [], accessKeys: [DiscoveredAccessKey] = [],
        knownHosts: [DiscoveredKnownHost] = [], diagnostics: OpenSSHScanDiagnostics = .init()
    ) {
        self.hosts = hosts; self.accessKeys = accessKeys
        self.knownHosts = knownHosts; self.diagnostics = diagnostics
    }
}

public struct OpenSSHHostExportRequest: Equatable, Sendable {
    public var alias: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var identityFiles: [URL]
    public var configURL: URL
    public var replaceExisting: Bool

    public init(
        alias: String, hostname: String, port: Int, username: String,
        identityFiles: [URL], configURL: URL, replaceExisting: Bool = false
    ) {
        self.alias = alias; self.hostname = hostname; self.port = port; self.username = username
        self.identityFiles = identityFiles; self.configURL = configURL; self.replaceExisting = replaceExisting
    }
}

public struct OpenSSHHostExportComparison: Equatable, Sendable {
    public var existingBlock: String
    public var proposedBlock: String

    public init(existingBlock: String, proposedBlock: String) {
        self.existingBlock = existingBlock; self.proposedBlock = proposedBlock
    }
}

public enum OpenSSHExportError: LocalizedError, Equatable, Sendable {
    case aliasConflict(existingBlock: String, proposedBlock: String)
    case fileConflict(URL)
    case invalidDestination

    public var errorDescription: String? {
        switch self {
        case .aliasConflict: "A Host block with this alias already exists. Compare it before updating."
        case .fileConflict(let url): TerminatorCoreLocalization.text("error.openSSH.fileConflict", url.path)
        case .invalidDestination: "The OpenSSH export destination is invalid."
        }
    }
}

public protocol OpenSSHIntegrationService: Sendable {
    func scan(knownEndpoints: [String]) async throws -> OpenSSHDiscoverySnapshot
    func hostBlock(for request: OpenSSHHostExportRequest) async -> String
    func comparison(for request: OpenSSHHostExportRequest) async throws -> OpenSSHHostExportComparison?
    func exportHost(_ request: OpenSSHHostExportRequest) async throws
    func writeKey(_ data: Data, to url: URL, privateKey: Bool, replaceExisting: Bool) async throws
}
