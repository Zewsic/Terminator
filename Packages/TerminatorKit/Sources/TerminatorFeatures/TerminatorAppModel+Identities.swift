import Foundation
import Observation
import TerminatorCore

extension TerminatorAppModel {
    public func saveIdentity(_ draft: IdentityDraft) async -> Bool {
        var journal = SecretMutationJournal(secretStore: secretStore)
        do {
            let existing = draft.id.flatMap { id in identities.first(where: { $0.id == id }) }
            let now = Date.now
            var methods: [AuthenticationMethod] = []
            for method in draft.authenticationMethods {
                switch method.kind {
                case .accessKey(let credentialID):
                    methods.append(.accessKey(credentialID: credentialID))
                case .password(let existingSecretID):
                    let value = method.password
                    let shouldReplace = method.passwordChanged || (existingSecretID == nil && !value.isEmpty)
                    if shouldReplace, !value.isEmpty {
                        guard let data = value.data(using: .utf8) else {
                            throw CredentialValidationError.missingSecret
                        }
                        let secretID = try await journal.create(data)
                        methods.append(.password(secretID: secretID))
                        journal.removeAfterCommit(existingSecretID)
                    } else if shouldReplace, let existingSecretID {
                        journal.removeAfterCommit(existingSecretID)
                    } else if let existingSecretID {
                        methods.append(.password(secretID: existingSecretID))
                    }
                }
            }
            let identity = IdentityProfile(
                id: existing?.id ?? draft.id ?? UUID(),
                name: draft.name,
                username: draft.username,
                authenticationMethods: methods,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                deletedAt: existing?.deletedAt
            )
            try await identityRepository.saveIdentity(identity)
            await journal.commitRemovals()
            await load()
            return true
        } catch {
            await journal.rollbackCreatedSecrets()
            present(error)
            return false
        }
    }

    public func loadIdentityPassword(into draft: IdentityDraft) async -> IdentityDraft {
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

    public func deleteIdentity(id: UUID) async {
        guard identityUsageCount(id: id) == 0 else {
            present(IdentityValidationError.identityInUse)
            return
        }
        do {
            try await identityRepository.deleteIdentity(id: id)
            ArchiveHintStore.shared.arm()
            await load()
        } catch { present(error) }
    }

    public func restoreIdentity(id: UUID) async -> Bool {
        do {
            try await identityRepository.restoreIdentity(id: id)
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func purgeIdentity(id: UUID) async -> Bool {
        guard identityUsageCount(id: id) == 0 else {
            present(IdentityValidationError.identityInUse)
            return false
        }
        do {
            try await identityRepository.purgeIdentity(id: id)
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func deleteCredential(id: UUID) async {
        guard credentialUsageCount(id: id) == 0 else {
            present(id: "credential-in-use", message: FeatureL10n.text(.errorCredentialInUse))
            return
        }
        do {
            try await credentialRepository.deleteCredential(id: id)
            ArchiveHintStore.shared.arm()
            await load()
        } catch { present(error) }
    }

    public func restoreCredential(id: UUID) async -> Bool {
        guard var credential = credentials.first(where: { $0.id == id }),
              credential.isDeleted, credential.isSecretAvailable else { return false }
        credential.deletedAt = nil
        do {
            try await credentialRepository.saveCredential(credential)
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func purgeCredential(id: UUID) async {
        guard credentialUsageCount(id: id) == 0,
              var credential = credentials.first(where: { $0.id == id }),
              credential.isSecretAvailable else {
            present(id: "credential-cannot-be-purged", message: FeatureL10n.text(.errorCredentialCannotBePurged))
            return
        }
        do {
            var journal = SecretMutationJournal(secretStore: secretStore)
            try await journal.backUp(credential.allSecretIDs)
            do {
                try await journal.purgeBackedUpSecrets()

                credential.secretPurgedAt = .now
                credential.deletedAt = credential.deletedAt ?? .now
                try await credentialRepository.saveCredential(credential)
            } catch {
                await journal.restorePurgedSecrets()
                throw error
            }
            await load()
        } catch { present(error) }
    }

    public func revert(historyEntryID: UUID) async {
        do {
            try await historyRepository.revert(historyEntryID: historyEntryID)
            await load()
        } catch { present(error) }
    }

    public func credentialUsageCount(id: UUID) -> Int {
        hosts.count { !$0.isDeleted && $0.authentication.credentialIDs.contains(id) }
            + identities.count { !$0.isDeleted && $0.credentialIDs.contains(id) }
    }

    public func identityUsageCount(id: UUID) -> Int {
        hosts.count { !$0.isDeleted && $0.authentication.identityID == id }
    }
}
