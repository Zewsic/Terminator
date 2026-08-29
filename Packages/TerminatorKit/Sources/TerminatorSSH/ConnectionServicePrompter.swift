import Foundation
import TerminatorCore

public protocol ConnectionPromptRouting: Sendable {
    func revealInterface() async
    func request(_ envelope: ConnectionPromptEnvelope) async throws -> ConnectionPromptReply
}

public actor ConnectionServicePrompter: SSHConnectionPrompting {
    private var router: (any ConnectionPromptRouting)?
    private var hostID: UUID?

    public init() {}

    public func attach(_ router: any ConnectionPromptRouting) {
        self.router = router
    }

    func bind(hostID: UUID) {
        self.hostID = hostID
    }

    public func requestPassphrase(for credential: CredentialMetadata) async throws -> String {
        try await text(from: .passphrase(credential: credential))
    }

    public func requestUsername(for host: HostProfile) async throws -> String {
        try await text(from: .username(host: host), hostID: host.id)
    }

    public func requestPassword(for host: HostProfile, username: String) async throws -> String {
        try await text(from: .password(host: host, username: username), hostID: host.id)
    }

    public func requestAuthentication(
        for host: HostProfile,
        username: String,
        availableAccessKeys: [CredentialMetadata],
        availableIdentities: [IdentityProfile]
    ) async throws -> ConnectionAuthenticationChoice {
        let reply = try await send(
            .authentication(
                host: host,
                username: username,
                availableAccessKeys: availableAccessKeys,
                availableIdentities: availableIdentities
            ),
            hostID: host.id
        )
        guard case .authentication(let choice) = reply else { throw CancellationError() }
        return choice
    }

    public func trustNewHost(_ key: KnownHostKey) async throws -> Bool {
        try await confirmed(from: .trustNewHost(key))
    }

    public func confirmChangedHost(previous: KnownHostKey, presented: KnownHostKey) async throws -> Bool {
        try await confirmed(from: .replaceHostKey(previous: previous, presented: presented))
    }

    public func requiresUserAttention(reason: String) async {
        await router?.revealInterface()
    }

    private func text(from kind: ConnectionPromptKind, hostID: UUID? = nil) async throws -> String {
        let reply = try await send(kind, hostID: hostID)
        guard case .text(let value) = reply, !value.isEmpty else { throw CancellationError() }
        return value
    }

    private func confirmed(from kind: ConnectionPromptKind) async throws -> Bool {
        switch try await send(kind) {
        case .confirmed, .text: true
        case .cancelled: throw CancellationError()
        case .authentication: throw CancellationError()
        }
    }

    private func send(_ kind: ConnectionPromptKind, hostID: UUID? = nil) async throws -> ConnectionPromptReply {
        guard let router else { throw ConnectionServiceError.unavailable }
        let envelope = ConnectionPromptEnvelope(hostID: hostID ?? self.hostID, kind: kind)
        let reply = try await router.request(envelope)
        if case .cancelled = reply { throw CancellationError() }
        return reply
    }
}
