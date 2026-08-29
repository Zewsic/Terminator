import Foundation
import Observation
import TerminatorCore

public struct ConnectionPromptRequest: Identifiable, Sendable {
    public typealias Kind = ConnectionPromptKind

    public let id: UUID
    public let kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

private enum ConnectionPromptAnswer: Sendable {
    case text(String)
    case authentication(ConnectionAuthenticationChoice)
    case confirmed
}

@MainActor
@Observable
public final class ConnectionPromptCenter {
    public private(set) var request: ConnectionPromptRequest?
    /// Called immediately before an interactive connection prompt becomes visible.
    /// The macOS app uses this to reveal a connection started by Spotlight/Raycast.
    public var onPrompt: (@MainActor @Sendable () -> Void)?
    private var continuation: CheckedContinuation<ConnectionPromptAnswer, any Error>?

    public init() {}

    public func submit(text: String = "") {
        guard let continuation else { return }
        self.continuation = nil
        request = nil
        continuation.resume(returning: text.isEmpty ? .confirmed : .text(text))
    }

    public func submit(authentication: ConnectionAuthenticationChoice) {
        guard let continuation else { return }
        self.continuation = nil
        request = nil
        continuation.resume(returning: .authentication(authentication))
    }

    public func cancel() {
        guard let continuation else {
            request = nil
            return
        }
        self.continuation = nil
        request = nil
        continuation.resume(throwing: CancellationError())
    }

    private func ask(_ kind: ConnectionPromptRequest.Kind) async throws -> ConnectionPromptAnswer {
        if continuation != nil { cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            request = ConnectionPromptRequest(kind: kind)
            onPrompt?()
        }
    }
}

extension ConnectionPromptCenter: SSHConnectionPrompting {
    public func requestPassphrase(for credential: CredentialMetadata) async throws -> String {
        guard case .text(let value) = try await ask(.passphrase(credential: credential)), !value.isEmpty else {
            throw CancellationError()
        }
        return value
    }

    public func requestUsername(for host: HostProfile) async throws -> String {
        guard case .text(let value) = try await ask(.username(host: host)), !value.isEmpty else {
            throw CancellationError()
        }
        return value
    }

    public func requestPassword(for host: HostProfile, username: String) async throws -> String {
        guard case .text(let value) = try await ask(.password(host: host, username: username)), !value.isEmpty else {
            throw CancellationError()
        }
        return value
    }

    public func requestAuthentication(
        for host: HostProfile,
        username: String,
        availableAccessKeys: [CredentialMetadata],
        availableIdentities: [IdentityProfile]
    ) async throws -> ConnectionAuthenticationChoice {
        guard case .authentication(let choice) = try await ask(.authentication(
            host: host,
            username: username,
            availableAccessKeys: availableAccessKeys,
            availableIdentities: availableIdentities
        )), !choice.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            choice.identityID != nil || choice.password?.isEmpty == false || choice.credentialID != nil else {
            throw CancellationError()
        }
        return choice
    }

    public func trustNewHost(_ key: KnownHostKey) async throws -> Bool {
        _ = try await ask(.trustNewHost(key))
        return true
    }

    public func confirmChangedHost(previous: KnownHostKey, presented: KnownHostKey) async throws -> Bool {
        _ = try await ask(.replaceHostKey(previous: previous, presented: presented))
        return true
    }

    public func requiresUserAttention(reason: String) async {
        onPrompt?()
    }

    public func requestKeychainAttention(reason: String) async throws {
        _ = try await ask(.keychain(reason: reason))
    }
}
