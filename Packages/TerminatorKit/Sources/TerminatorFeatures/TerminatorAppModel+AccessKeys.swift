import Foundation
import Observation
import TerminatorCore

extension TerminatorAppModel {
    public func saveAccessKey(_ draft: AccessKeyDraft) async -> UUID? {
        if draft.credentialID != nil {
            return await replaceAccessKey(draft) ? draft.credentialID : nil
        }
        guard draft.passphrase == draft.passphraseConfirmation else {
            present(id: "passphrases-do-not-match", message: FeatureL10n.text(.errorPassphrasesDoNotMatch))
            return nil
        }
        var journal = SecretMutationJournal(secretStore: secretStore)
        do {
            let label = resolvedAccessKeyLabel(for: draft)
            let prepared: PreparedAccessKey
            let origin: AccessKeyOrigin
            switch draft.mode {
            case .importExisting:
                prepared = try await accessKeyService.importSoftwareKey(AccessKeyImportRequest(
                    privateKey: draft.privateKey,
                    suppliedPublicKey: draft.publicKey,
                    passphrase: draft.passphrase
                ))
                origin = .imported
            case .generateSoftware:
                prepared = try await accessKeyService.generateSoftwareKey(AccessKeyGenerationRequest(
                    algorithm: draft.generation,
                    comment: draft.comment,
                    passphrase: draft.passphrase
                ))
                origin = .generated
            case .generateSecureEnclave:
                prepared = try await accessKeyService.generateSecureEnclaveKey(label: label)
                origin = .generated
            }

            if draft.mode == .importExisting,
               let existing = activeCredentials.first(where: { $0.accessKey?.fingerprint == prepared.fingerprint }) {
                if !suppressesImportAnnouncements {
                    openSSHResultMessage = FeatureL10n.text(.opensshCredentialReused, existing.label)
                }
                return existing.id
            }

            if prepared.compatibility == .legacyRSA1024, !draft.acceptLegacyRSA1024 {
                throw AccessKeyImportPolicyError.legacyRSAConfirmationRequired
            }

            let privateID = SecretID()
            var privateMaterial = prepared.privateMaterial
            var protection: PassphraseProtection = prepared.isPassphraseProtected ? .promptEveryConnection : .none
            if prepared.isPassphraseProtected, !draft.passphrase.isEmpty, !draft.savePassphrase {
                privateMaterial = try await accessKeyService.exportSoftwareKey(
                    privateMaterial: prepared.privateMaterial,
                    passphrase: draft.passphrase
                )
                protection = .none
            }
            _ = try await journal.create(privateMaterial, id: privateID)
            if prepared.isPassphraseProtected, draft.savePassphrase, !draft.passphrase.isEmpty,
               let data = draft.passphrase.data(using: .utf8) {
                let passphraseID = SecretID()
                _ = try await journal.create(data, id: passphraseID, access: .userPresence)
                protection = .saved(secretID: passphraseID)
            }

            let key = AccessKeyMetadata(
                algorithm: prepared.algorithm,
                backend: prepared.backend,
                origin: origin,
                publicKey: prepared.publicKey,
                fingerprint: prepared.fingerprint,
                privateMaterialID: privateID,
                passphraseProtection: protection,
                compatibility: prepared.compatibility
            )
            let credential = CredentialMetadata(
                label: label,
                kind: .accessKey,
                secretID: privateID,
                accessKey: key
            )
            try await credentialRepository.saveCredential(credential)
            await load()
            return credential.id
        } catch {
            await journal.rollbackCreatedSecrets()
            present(error)
            return nil
        }
    }

    public func accessKeyDraft(id: UUID, unlockingWith suppliedPassphrase: String = "") async -> AccessKeyDraft? {
        guard let credential = credentials.first(where: { $0.id == id }),
              let key = credential.accessKey else { return nil }

        var draft = AccessKeyDraft()
        draft.credentialID = id
        draft.label = credential.label
        draft.mode = key.backend == .secureEnclave ? .generateSecureEnclave : .importExisting
        draft.publicKey = key.publicKey
        draft.originalAlgorithm = key.algorithm
        draft.acceptLegacyRSA1024 = key.compatibility == .legacyRSA1024

        guard key.backend == .software, credential.isSecretAvailable else { return draft }
        do {
            let passphrase: String
            switch key.passphraseProtection {
            case .none:
                passphrase = ""
            case .saved(let secretID):
                let data = try await secretStore.read(id: secretID)
                guard let value = String(data: data, encoding: .utf8) else {
                    throw AccessKeyServiceError.invalidPassphrase
                }
                passphrase = value
                draft.savePassphrase = true
            case .promptEveryConnection:
                guard !suppliedPassphrase.isEmpty else {
                    draft.requiresUnlock = true
                    return draft
                }
                passphrase = suppliedPassphrase
            }
            try await userPresenceAuthorizer.authorize(reason: FeatureL10n.text(.authenticationRevealPrivateKey, credential.label))
            let material = try await secretStore.read(id: key.privateMaterialID)
            let clear = try await accessKeyService.exportSoftwareKey(
                privateMaterial: material,
                passphrase: passphrase
            )
            guard let privateKey = String(data: clear, encoding: .utf8) else {
                throw AccessKeyServiceError.invalidPrivateKey
            }
            draft.privateKey = privateKey
            draft.passphrase = passphrase
            draft.passphraseConfirmation = passphrase
            draft.requiresUnlock = false
            return draft
        } catch {
            present(error)
            return draft
        }
    }

    public func replaceAccessKey(_ draft: AccessKeyDraft) async -> Bool {
        guard let id = draft.credentialID,
              var credential = credentials.first(where: { $0.id == id }),
              let current = credential.accessKey else { return false }
        if current.backend == .secureEnclave {
            do {
                credential.label = resolvedAccessKeyLabel(for: draft)
                try await credentialRepository.saveCredential(credential)
                await load()
                return true
            } catch {
                present(error)
                return false
            }
        }
        if draft.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !draft.passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                present(id: "private-key-locked", message: FeatureL10n.text(.errorLoadOrUnlockPrivateKey))
                return false
            }
            do {
                credential.label = resolvedAccessKeyLabel(for: draft)
                try await credentialRepository.saveCredential(credential)
                await load()
                return true
            } catch {
                present(error)
                return false
            }
        }
        guard draft.passphrase == draft.passphraseConfirmation else {
            present(id: "passphrases-do-not-match", message: FeatureL10n.text(.errorPassphrasesDoNotMatch))
            return false
        }
        guard !draft.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            present(id: "private-key-missing", message: FeatureL10n.text(.errorLoadOrUnlockPrivateKey))
            return false
        }

        var journal = SecretMutationJournal(secretStore: secretStore)
        do {
            let prepared = try await accessKeyService.importSoftwareKey(.init(
                privateKey: draft.privateKey,
                suppliedPublicKey: draft.publicKey,
                passphrase: draft.passphrase
            ))
            if prepared.compatibility == .legacyRSA1024, !draft.acceptLegacyRSA1024 {
                throw AccessKeyImportPolicyError.legacyRSAConfirmationRequired
            }

            let privateID = SecretID()
            var privateMaterial = prepared.privateMaterial
            var protection: PassphraseProtection = prepared.isPassphraseProtected ? .promptEveryConnection : .none
            if prepared.isPassphraseProtected, !draft.passphrase.isEmpty, !draft.savePassphrase {
                privateMaterial = try await accessKeyService.exportSoftwareKey(
                    privateMaterial: prepared.privateMaterial,
                    passphrase: draft.passphrase
                )
                protection = .none
            }
            var newItems: [(SecretID, Data, SecretAccessPolicy)] = [(privateID, privateMaterial, .deviceOnly)]
            if prepared.isPassphraseProtected, draft.savePassphrase,
               let data = draft.passphrase.data(using: .utf8), !data.isEmpty {
                let passphraseID = SecretID()
                newItems.append((passphraseID, data, .userPresence))
                protection = .saved(secretID: passphraseID)
            }

            for (secretID, data, access) in newItems {
                _ = try await journal.create(data, id: secretID, access: access)
            }

            credential.label = resolvedAccessKeyLabel(for: draft)
            credential.secretID = privateID
            credential.secretPurgedAt = nil
            credential.accessKey = AccessKeyMetadata(
                algorithm: prepared.algorithm,
                backend: .software,
                origin: .imported,
                publicKey: prepared.publicKey,
                fingerprint: prepared.fingerprint,
                privateMaterialID: privateID,
                passphraseProtection: protection,
                compatibility: prepared.compatibility
            )
            try await credentialRepository.saveCredential(credential)
            // Previous handles remain available for append-only history revert.
            // They are purged with the credential, never before its snapshots expire.
            await load()
            return true
        } catch {
            await journal.rollbackCreatedSecrets()
            present(error)
            return false
        }
    }

    public func exportPrivateKey(id: UUID, passphrase suppliedPassphrase: String = "") async -> Data? {
        guard let credential = credentials.first(where: { $0.id == id }),
              credential.kind == .accessKey,
              let key = credential.accessKey else { return nil }
        guard key.backend == .software else {
            present(AccessKeyServiceError.secureEnclaveKeyIsNotExportable)
            return nil
        }
        do {
            try await userPresenceAuthorizer.authorize(reason: FeatureL10n.text(.authenticationExportPrivateKey, credential.label))
            let material = try await secretStore.read(id: key.privateMaterialID)
            let passphrase: String
            switch key.passphraseProtection {
            case .none:
                passphrase = ""
            case .promptEveryConnection:
                guard !suppliedPassphrase.isEmpty else { throw AccessKeyServiceError.passphraseRequired }
                passphrase = suppliedPassphrase
            case .saved(let secretID):
                let data = try await secretStore.read(id: secretID)
                guard let value = String(data: data, encoding: .utf8) else {
                    throw AccessKeyServiceError.invalidPassphrase
                }
                passphrase = value
            }
            return try await accessKeyService.exportSoftwareKey(privateMaterial: material, passphrase: passphrase)
        } catch {
            present(error)
            return nil
        }
    }

    private func resolvedAccessKeyLabel(for draft: AccessKeyDraft) -> String {
        let explicit = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard explicit.isEmpty else { return explicit }
        let ordinal = draft.suggestedOrdinal ?? (
            credentials.filter { $0.kind == .accessKey && $0.id != draft.credentialID }.count + 1
        )
        let context = draft.suggestedLabelContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context, !context.isEmpty else { return FeatureL10n.text(.keyAutomaticLabel, ordinal) }
        return FeatureL10n.text(.keyAutomaticLabelContext, ordinal, context)
    }

}
