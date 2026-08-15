#if !APP_STORE
import AppKit
import Foundation
import TerminatorCore
import TerminatorFeatures
final class MacConnectionPrompter: SSHConnectionPrompting, @unchecked Sendable {
    let center: ConnectionPromptCenter

    init(center: ConnectionPromptCenter) { self.center = center }

    func requestPassphrase(for credential: CredentialMetadata) async throws -> String {
        await activateApplication()
        return try await center.requestPassphrase(for: credential)
    }

    func requestUsername(for host: HostProfile) async throws -> String {
        await activateApplication()
        return try await center.requestUsername(for: host)
    }

    func requestPassword(for host: HostProfile, username: String) async throws -> String {
        await activateApplication()
        return try await center.requestPassword(for: host, username: username)
    }

    func requestAuthentication(
        for host: HostProfile,
        username: String,
        availableAccessKeys: [CredentialMetadata],
        availableIdentities: [IdentityProfile]
    ) async throws -> ConnectionAuthenticationChoice {
        await activateApplication()
        return try await center.requestAuthentication(
            for: host,
            username: username,
            availableAccessKeys: availableAccessKeys,
            availableIdentities: availableIdentities
        )
    }

    func trustNewHost(_ key: KnownHostKey) async throws -> Bool {
        await activateApplication()
        return try await center.trustNewHost(key)
    }

    func confirmChangedHost(previous: KnownHostKey, presented: KnownHostKey) async throws -> Bool {
        await activateApplication()
        return try await center.confirmChangedHost(previous: previous, presented: presented)
    }

    func requiresUserAttention(reason: String) async {
        await activateApplication()
    }

    private func activateApplication() async {
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
    }
}

#endif
