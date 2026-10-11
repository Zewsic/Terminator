import Foundation
import Observation
import TerminatorCore

extension TerminatorAppModel {
    public func saveHost(_ draft: HostDraft) async -> Bool {
        var journal = SecretMutationJournal(secretStore: secretStore)
        do {
            let existing = draft.id.flatMap { id in hosts.first(where: { $0.id == id }) }
            let now = Date.now
            let authentication: HostAuthentication
            if draft.usesIdentity, let identityID = draft.identityID {
                authentication = .identity(identityID)
            } else {
                var methods: [AuthenticationMethod] = []
                for method in draft.authenticationMethods {
                    switch method.kind {
                    case .accessKey(let credentialID):
                        methods.append(.accessKey(credentialID: credentialID))
                    case .password(let existingSecretID):
                        let value = method.password
                        let shouldReplace = method.passwordChanged || (existingSecretID == nil && !value.isEmpty)
                        if shouldReplace, !value.isEmpty {
                            let secretID = try await journal.create(Data(value.utf8))
                            methods.append(.password(secretID: secretID))
                            journal.removeAfterCommit(existingSecretID)
                        } else if shouldReplace, let existingSecretID {
                            journal.removeAfterCommit(existingSecretID)
                        } else if let existingSecretID {
                            methods.append(.password(secretID: existingSecretID))
                        }
                    }
                }
                authentication = .manual(username: draft.username, authenticationMethods: methods)
            }
            let host = HostProfile(
                id: existing?.id ?? draft.id ?? UUID(),
                displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? draft.hostname
                    : draft.displayName,
                hostname: draft.hostname,
                port: draft.port,
                authentication: authentication,
                group: draft.group,
                tags: draft.tags,
                notes: draft.notes,
                sessionPersistence: draft.sessionPersistence,
                remoteShell: draft.remoteShell,
                connectCommands: draft.connectCommands,
                detectedOS: existing?.detectedOS,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                deletedAt: existing?.deletedAt
            )
            try await hostRepository.saveHost(host)
            await journal.commitRemovals()
            await load()
            return true
        } catch {
            await journal.rollbackCreatedSecrets()
            present(error)
            return false
        }
    }

    public func loadHostPassword(into draft: HostDraft) async -> HostDraft {
        var copy = draft
        guard let index = copy.authenticationMethods.firstIndex(where: { method in
            if case .password(let id) = method.kind { return id != nil }
            return false
        }), case .password(let secretID?) = copy.authenticationMethods[index].kind else {
            return copy
        }
        do {
            let data = try await secretStore.read(id: secretID)
            guard let value = String(data: data, encoding: .utf8) else {
                throw CredentialValidationError.missingSecret
            }
            copy.authenticationMethods[index].password = value
            copy.authenticationMethods[index].passwordChanged = false
        } catch {
            present(error)
        }
        return copy
    }

    public func deleteHost(id: UUID) async {
        do {
            try await hostRepository.deleteHost(id: id)
            await load()
        } catch { present(error) }
    }

}
