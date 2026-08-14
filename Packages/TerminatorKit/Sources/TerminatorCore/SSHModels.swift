import Foundation

public enum SSHConnectionPhase: Equatable, Sendable {
    case disconnected
    case resolving
    case verifyingHost(fingerprint: String)
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case waitingForUser(message: String)
    case failed(message: String)
}

public enum SSHSessionEvent: Equatable, Sendable {
    case stdout(Data)
    case stderr(Data)
    case status(String)
    case exited(Int?)
}

public struct SSHSessionHandle: Sendable {
    public var id: UUID
    public var logID: UUID
    public var events: AsyncStream<SSHSessionEvent>
    private let writer: @Sendable (Data) async throws -> Void
    private let resizer: @Sendable (TerminalSize) async throws -> Void
    private let closer: @Sendable () async -> Void

    public init(
        id: UUID,
        logID: UUID,
        events: AsyncStream<SSHSessionEvent>,
        writer: @escaping @Sendable (Data) async throws -> Void,
        resizer: @escaping @Sendable (TerminalSize) async throws -> Void,
        closer: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.logID = logID
        self.events = events
        self.writer = writer
        self.resizer = resizer
        self.closer = closer
    }

    public func write(_ data: Data) async throws { try await writer(data) }
    public func resize(to size: TerminalSize) async throws { try await resizer(size) }
    public func close() async { await closer() }
}

public protocol SSHConnectionCoordinating: Sendable {
    func prepare(host: HostProfile, prompting: any SSHConnectionPrompting) async throws
    func openSession(host: HostProfile, terminal: TerminalApplication, size: TerminalSize) async throws -> SSHSessionHandle
    func state(for hostID: UUID) async -> SSHConnectionPhase
    func disconnect(hostID: UUID) async
}

public protocol SSHConnectionPrompting: CredentialPrompting {
    func trustNewHost(_ key: KnownHostKey) async throws -> Bool
    func confirmChangedHost(previous: KnownHostKey, presented: KnownHostKey) async throws -> Bool
    func requiresUserAttention(reason: String) async
}

public struct KnownHostKey: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var endpoint: String
    public var algorithm: String
    public var publicKey: Data
    public var fingerprint: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), endpoint: String, algorithm: String, publicKey: Data,
        fingerprint: String, createdAt: Date = .now, updatedAt: Date = .now
    ) {
        self.id = id; self.endpoint = endpoint; self.algorithm = algorithm
        self.publicKey = publicKey; self.fingerprint = fingerprint
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum TerminalApplication: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal, iTerm2, warp, ghostty, wezTerm, other
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm2: "iTerm2"
        case .warp: "Warp"
        case .ghostty: "Ghostty"
        case .wezTerm: "WezTerm"
        case .other: "Other…"
        }
    }
}

public struct AttachDescriptor: Codable, Equatable, Sendable {
    public static let protocolVersion: UInt16 = 1
    public var sessionID: UUID
    public var socketPath: String
    public var token: String
    public var expiresAt: Date

    public init(sessionID: UUID, socketPath: String, token: String, expiresAt: Date) {
        self.sessionID = sessionID; self.socketPath = socketPath
        self.token = token; self.expiresAt = expiresAt
    }
}

public protocol ExternalTerminalConnecting: Sendable {
    func installedApplications() async -> [TerminalApplication]
    func connect(host: HostProfile, terminal: TerminalApplication) async throws
    func makeConnectionCommand(host: HostProfile) async throws -> String
    func state(for hostID: UUID) async -> SSHConnectionPhase
    func disconnect(hostID: UUID) async
}

public protocol SessionLogExporting: Sendable {
    func export(_ log: SessionLogMetadata) async throws -> URL?
}

public enum SessionLogState: String, Codable, Sendable { case active, complete, incomplete }
public enum SessionLogEventKind: UInt8, Codable, Sendable { case stdout = 1, stderr = 2, status = 3 }

public struct SessionLogMetadata: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var hostDisplayName: String
    public var terminal: TerminalApplication
    public var startedAt: Date
    public var endedAt: Date?
    public var byteCount: Int64
    public var reconnectCount: Int
    public var state: SessionLogState
    public var isPinned: Bool
    public var relativePath: String
    public var encryptionKeyID: SecretID

    public init(
        id: UUID = UUID(), hostID: UUID, hostDisplayName: String, terminal: TerminalApplication,
        startedAt: Date = .now, endedAt: Date? = nil, byteCount: Int64 = 0,
        reconnectCount: Int = 0, state: SessionLogState = .active, isPinned: Bool = false,
        relativePath: String, encryptionKeyID: SecretID
    ) {
        self.id = id; self.hostID = hostID; self.hostDisplayName = hostDisplayName
        self.terminal = terminal; self.startedAt = startedAt; self.endedAt = endedAt
        self.byteCount = byteCount; self.reconnectCount = reconnectCount
        self.state = state; self.isPinned = isPinned; self.relativePath = relativePath
        self.encryptionKeyID = encryptionKeyID
    }
}

public enum SSHPrivateKeyMaterial: Sendable {
    case ed25519(seed: Data)
    case ecdsa(curve: ECDSACurve, scalar: Data)
    case rsa(modulus: Data, exponent: Data, privateExponent: Data, p: Data, q: Data, iqmp: Data)
}
