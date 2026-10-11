import Foundation

public enum ConnectionPromptKind: Codable, Sendable {
    case passphrase(credential: CredentialMetadata)
    case username(host: HostProfile)
    case password(host: HostProfile, username: String)
    case authentication(
        host: HostProfile,
        username: String,
        availableAccessKeys: [CredentialMetadata],
        availableIdentities: [IdentityProfile]
    )
    case trustNewHost(KnownHostKey)
    case replaceHostKey(previous: KnownHostKey, presented: KnownHostKey)
    case keychain(reason: String)
}

public struct ConnectionPromptEnvelope: Codable, Identifiable, Sendable {
    public var id: UUID
    public var hostID: UUID?
    public var kind: ConnectionPromptKind

    public init(id: UUID = UUID(), hostID: UUID? = nil, kind: ConnectionPromptKind) {
        self.id = id
        self.hostID = hostID
        self.kind = kind
    }
}

public enum ConnectionPromptReply: Codable, Sendable {
    case text(String)
    case authentication(ConnectionAuthenticationChoice)
    case confirmed
    case cancelled
}

public enum ConnectionControlRequest: Codable, Sendable {
    case subscribe
    case connect(hostID: UUID, terminal: TerminalApplication)
    case command(hostID: UUID)
    case disconnect(hostID: UUID)
    case state(hostID: UUID)
    case answer(promptID: UUID, reply: ConnectionPromptReply)
    case listHosts
    case connectHeadless(hostID: UUID)
    case listSessions
    case sessionWrite(sessionID: UUID, text: String)
    case sessionRead(sessionID: UUID, after: Int)
    case exec(hostID: UUID, command: String)
    case startTunnel(TunnelProfile)
    case stopTunnel(UUID)
}

public enum ConnectionControlResponse: Codable, Sendable {
    case ok
    case phase(SSHConnectionPhase)
    case command(String)
    case failed(String)
    case hosts([HostAccessSummary])
    case sessionID(UUID)
    case sessions([SessionAccessSummary])
    case sessionOutput(text: String, next: Int)
    case exec(stdout: String, stderr: String, exitCode: Int)
    case connected(detectedOS: DetectedHostOS?)
}

public struct HostAccessSummary: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var phase: SSHConnectionPhase

    public init(id: UUID, name: String, hostname: String, port: Int, phase: SSHConnectionPhase) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.phase = phase
    }
}

public struct SessionAccessSummary: Codable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var hostName: String
    public var kind: String

    public init(id: UUID, hostID: UUID, hostName: String, kind: String) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.kind = kind
    }
}

public enum ConnectionControlEvent: Codable, Sendable {
    case phase(hostID: UUID, SSHConnectionPhase)
    case prompt(ConnectionPromptEnvelope)
    case tunnelPhase(TunnelPhaseEvent)
}

public enum ConnectionControlFrame: Codable, Sendable {
    case request(id: UUID, ConnectionControlRequest)
    case response(id: UUID, ConnectionControlResponse)
    case event(ConnectionControlEvent)
}

public enum ConnectionServiceError: LocalizedError, Equatable, Sendable {
    case unavailable
    case hostNotFound
    case promptTimedOut
    case cliDisabled
    case mcpDisabled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: TerminatorCoreLocalization.text(.errorConnectionServiceUnavailable)
        case .hostNotFound: TerminatorCoreLocalization.text(.errorStoreHostNotFound)
        case .promptTimedOut: TerminatorCoreLocalization.text(.errorConnectionPromptTimedOut)
        case .cliDisabled: TerminatorCoreLocalization.text(.errorAccessCLIDisabled)
        case .mcpDisabled: TerminatorCoreLocalization.text(.errorAccessMCPDisabled)
        case .failed(let message): message
        }
    }
}

public enum TerminatorDistributedNotification: Sendable {
    public static let revealGUI = "pro.zewsic.terminator.revealMainWindow"
    public static let accessChanged = "pro.zewsic.terminator.accessChanged"
}

public enum ConnectionServicePaths: Sendable {
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Terminator", directoryHint: .isDirectory)
    }

    public static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Terminator.store")
    }

    public static var controlSocketURL: URL {
        applicationSupport.appending(path: "control.sock")
    }

    public static var serviceLockURL: URL {
        applicationSupport.appending(path: "connection-service.lock")
    }

    public static var attachDirectoryURL: URL {
        applicationSupport.appending(path: "Attach", directoryHint: .isDirectory)
    }

    public static var sessionLogURL: URL {
        applicationSupport.appending(path: "SessionLogs", directoryHint: .isDirectory)
    }
}
