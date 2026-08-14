import Foundation
import Testing
import TerminatorCore
import TerminatorFeatures
import TerminatorTestSupport

@MainActor
@Suite("Application model")
struct TerminatorAppModelTests {
    @Test("OpenSSH host matching compares endpoint and update preserves authentication")
    func openSSHHostComparisonAndUpdate() async throws {
        let keyID = UUID()
        let passwordID = SecretID()
        let existing = HostProfile(
            displayName: "Old alias", hostname: "SERVER.EXAMPLE.COM.", port: 2222,
            authentication: .manual(username: "deploy", authenticationMethods: [
                .password(secretID: passwordID), .accessKey(credentialID: keyID),
            ])
        )
        let catalog = InMemoryTerminatorStore(hosts: [existing])
        let model = TerminatorAppModel(
            capabilities: .direct,
            hostRepository: catalog, credentialRepository: catalog,
            identityRepository: catalog, historyRepository: catalog,
            secretStore: InMemorySecretStore(), accessKeyService: MockAccessKeyService(),
            userPresenceAuthorizer: AllowingUserPresenceAuthorizer(),
            dockerService: MockDockerService(containers: []),
            openSSHService: MockOpenSSHIntegrationService()
        )
        await model.load()
        let discovered = DiscoveredSSHHost(
            alias: "New alias", hostname: "server.example.com", port: 2222,
            username: "DEPLOY", sourceURL: URL(fileURLWithPath: "/tmp/config")
        )

        #expect(model.matchingHost(for: discovered)?.id == existing.id)
        #expect(await model.importHost(discovered, credentialIDs: []))
        let updated = try #require(model.hosts.first)
        #expect(updated.id == existing.id)
        #expect(updated.displayName == "New alias")
        #expect(updated.authentication.authenticationMethods == existing.authentication.authenticationMethods)
    }

    @Test("Host and access key names are inferred when omitted")
    func inferredNames() async throws {
        let catalog = InMemoryTerminatorStore()
        let model = TerminatorAppModel(
            capabilities: .direct,
            hostRepository: catalog,
            credentialRepository: catalog,
            identityRepository: catalog,
            historyRepository: catalog,
            secretStore: InMemorySecretStore(),
            accessKeyService: MockAccessKeyService(),
            userPresenceAuthorizer: AllowingUserPresenceAuthorizer(),
            dockerService: MockDockerService(containers: [])
        )

        var host = HostDraft()
        host.hostname = "server.example.com"
        host.username = "deploy"
        #expect(await model.saveHost(host))
        #expect(model.hosts.first?.displayName == "server.example.com")

        var key = AccessKeyDraft()
        key.suggestedLabelContext = "server.example.com"
        key.suggestedOrdinal = 2
        let keyID = try #require(await model.saveAccessKey(key))
        #expect(model.credentials.first { $0.id == keyID }?.label == "Key #2 for “server.example.com”")
    }

    @Test("Identity and manual host passwords are embedded methods, not credentials")
    func embeddedPasswords() async throws {
        let catalog = InMemoryTerminatorStore()
        let secrets = InMemorySecretStore()
        let model = TerminatorAppModel(
            capabilities: .direct,
            hostRepository: catalog,
            credentialRepository: catalog,
            identityRepository: catalog,
            historyRepository: catalog,
            secretStore: secrets,
            accessKeyService: MockAccessKeyService(),
            userPresenceAuthorizer: AllowingUserPresenceAuthorizer(),
            dockerService: MockDockerService(containers: [])
        )

        var identity = IdentityDraft()
        identity.name = "Production"
        identity.username = "deploy"
        var identityPassword = IdentityDraftMethod(kind: .password(existingSecretID: nil))
        identityPassword.password = "identity-secret"
        identity.authenticationMethods = [identityPassword]
        #expect(await model.saveIdentity(identity))
        let savedIdentity = try #require(model.identities.first)
        let identitySecretID = try #require(savedIdentity.passwordSecretID)
        #expect(try await secrets.read(id: identitySecretID) == Data("identity-secret".utf8))
        #expect(model.credentials.isEmpty)

        var host = HostDraft()
        host.displayName = "Manual"
        host.hostname = "manual.example.com"
        host.usesIdentity = false
        host.username = "root"
        var hostPassword = IdentityDraftMethod(kind: .password(existingSecretID: nil))
        hostPassword.password = "host-secret"
        host.authenticationMethods = [hostPassword]
        #expect(await model.saveHost(host))
        let savedHost = try #require(model.hosts.first)
        let hostSecretID = try #require(savedHost.authentication.authenticationMethods.first?.passwordSecretID)
        #expect(try await secrets.read(id: hostSecretID) == Data("host-secret".utf8))
        #expect(model.credentials.isEmpty)
    }

    @Test("Encrypted access keys support prompt, automatic, and Touch ID modes")
    func encryptedKeyPassphraseModes() async throws {
        let encrypted = Data("encrypted-private-key".utf8)
        let clear = Data("clear-private-key".utf8)
        let prepared = PreparedAccessKey(
            privateMaterial: encrypted,
            algorithm: .ed25519,
            backend: .software,
            publicKey: "ssh-ed25519 bW9jaw==",
            fingerprint: "SHA256:mock",
            isPassphraseProtected: true
        )

        func makeModel(
            catalog: InMemoryTerminatorStore,
            secrets: InMemorySecretStore
        ) -> TerminatorAppModel {
            TerminatorAppModel(
                capabilities: .direct,
                hostRepository: catalog,
                credentialRepository: catalog,
                identityRepository: catalog,
                historyRepository: catalog,
                secretStore: secrets,
                accessKeyService: MockAccessKeyService(
                    preparedKey: prepared,
                    exportedPrivateMaterial: clear
                ),
                userPresenceAuthorizer: AllowingUserPresenceAuthorizer(),
                dockerService: MockDockerService(containers: [])
            )
        }

        let promptCatalog = InMemoryTerminatorStore()
        let promptSecrets = InMemorySecretStore()
        let promptModel = makeModel(catalog: promptCatalog, secrets: promptSecrets)
        var promptDraft = AccessKeyDraft()
        promptDraft.mode = .importExisting
        promptDraft.privateKey = "encrypted"
        let promptID = try #require(await promptModel.saveAccessKey(promptDraft))
        let promptKey = try #require(promptModel.credentials.first { $0.id == promptID }?.accessKey)
        #expect(promptKey.passphraseProtection == .promptEveryConnection)
        #expect(try await promptSecrets.read(id: promptKey.privateMaterialID) == encrypted)

        let automaticCatalog = InMemoryTerminatorStore()
        let automaticSecrets = InMemorySecretStore()
        let automaticModel = makeModel(catalog: automaticCatalog, secrets: automaticSecrets)
        var automaticDraft = promptDraft
        automaticDraft.id = UUID()
        automaticDraft.passphrase = "phrase"
        automaticDraft.passphraseConfirmation = "phrase"
        let automaticID = try #require(await automaticModel.saveAccessKey(automaticDraft))
        let automaticKey = try #require(automaticModel.credentials.first { $0.id == automaticID }?.accessKey)
        #expect(automaticKey.passphraseProtection == .none)
        #expect(try await automaticSecrets.read(id: automaticKey.privateMaterialID) == clear)

        let touchIDCatalog = InMemoryTerminatorStore()
        let touchIDSecrets = InMemorySecretStore()
        let touchIDModel = makeModel(catalog: touchIDCatalog, secrets: touchIDSecrets)
        var touchIDDraft = automaticDraft
        touchIDDraft.id = UUID()
        touchIDDraft.savePassphrase = true
        let touchIDCredentialID = try #require(await touchIDModel.saveAccessKey(touchIDDraft))
        let touchIDKey = try #require(touchIDModel.credentials.first { $0.id == touchIDCredentialID }?.accessKey)
        let passphraseID = try #require(touchIDKey.passphraseProtection.savedSecretID)
        #expect(try await touchIDSecrets.read(id: touchIDKey.privateMaterialID) == encrypted)
        #expect(try await touchIDSecrets.read(id: passphraseID) == Data("phrase".utf8))
        #expect(await touchIDSecrets.accessPolicy(id: passphraseID) == .userPresence)
    }

    @Test("Replacing an access key allocates new secrets and history restores old handles")
    func accessKeyReplacementAndRevert() async throws {
        let catalog = InMemoryTerminatorStore()
        let secrets = InMemorySecretStore()
        let model = TerminatorAppModel(
            capabilities: .direct,
            hostRepository: catalog,
            credentialRepository: catalog,
            identityRepository: catalog,
            historyRepository: catalog,
            secretStore: secrets,
            accessKeyService: MockAccessKeyService(),
            userPresenceAuthorizer: AllowingUserPresenceAuthorizer(),
            dockerService: MockDockerService(containers: [])
        )

        var originalDraft = AccessKeyDraft()
        originalDraft.label = "Deploy key"
        originalDraft.passphrase = "old phrase"
        originalDraft.passphraseConfirmation = "old phrase"
        originalDraft.savePassphrase = true
        let credentialID = try #require(await model.saveAccessKey(originalDraft))
        let original = try #require(model.credentials.first { $0.id == credentialID })
        let originalKey = try #require(original.accessKey)
        let originalMaterial = try await secrets.read(id: originalKey.privateMaterialID)
        let originalPassphraseID = try #require(originalKey.passphraseProtection.savedSecretID)

        var replacement = AccessKeyDraft()
        replacement.credentialID = credentialID
        replacement.label = "Rotated deploy key"
        replacement.mode = .importExisting
        replacement.privateKey = "replacement private key"
        replacement.publicKey = ""
        replacement.passphrase = "new phrase"
        replacement.passphraseConfirmation = "new phrase"
        replacement.savePassphrase = true
        #expect(await model.replaceAccessKey(replacement))

        let rotated = try #require(model.credentials.first { $0.id == credentialID })
        let rotatedKey = try #require(rotated.accessKey)
        #expect(rotatedKey.privateMaterialID != originalKey.privateMaterialID)
        #expect(try await secrets.read(id: originalKey.privateMaterialID) == originalMaterial)
        #expect(try await secrets.read(id: originalPassphraseID) == Data("old phrase".utf8))

        let update = try #require(model.history.first { $0.entityID == credentialID && $0.operation == .updated })
        await model.revert(historyEntryID: update.id)
        let restored = try #require(model.credentials.first { $0.id == credentialID })
        #expect(restored.accessKey?.privateMaterialID == originalKey.privateMaterialID)
        #expect(restored.accessKey?.passphraseProtection.savedSecretID == originalPassphraseID)
    }
}
