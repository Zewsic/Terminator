import Foundation
import Testing
import TerminatorCore
import TerminatorFeatures
import TerminatorTestSupport

@MainActor
@Suite("Application model")
struct TerminatorAppModelTests {
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
