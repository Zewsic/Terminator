import Foundation
import Observation
import TerminatorCore

public struct ConnectionPromptRequest: Identifiable, Sendable {
    public enum Kind: Sendable {
        case passphrase(credential: CredentialMetadata)
        case trustNewHost(KnownHostKey)
        case replaceHostKey(previous: KnownHostKey, presented: KnownHostKey)
    }

    public let id: UUID
    public let kind: Kind

    init(kind: Kind) {
        self.id = UUID()
        self.kind = kind
    }
}

private enum ConnectionPromptAnswer: Sendable {
    case text(String)
    case confirmed
}

@MainActor
@Observable
public final class ConnectionPromptCenter {
    public private(set) var request: ConnectionPromptRequest?
    private var continuation: CheckedContinuation<ConnectionPromptAnswer, any Error>?

    public init() {}

    public func submit(text: String = "") {
        guard let continuation else { return }
        self.continuation = nil
        request = nil
        continuation.resume(returning: text.isEmpty ? .confirmed : .text(text))
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

    public func trustNewHost(_ key: KnownHostKey) async throws -> Bool {
        _ = try await ask(.trustNewHost(key))
        return true
    }

    public func confirmChangedHost(previous: KnownHostKey, presented: KnownHostKey) async throws -> Bool {
        _ = try await ask(.replaceHostKey(previous: previous, presented: presented))
        return true
    }

    public func requiresUserAttention(reason: String) async {}
}
