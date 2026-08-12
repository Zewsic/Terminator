import Foundation
import Testing
import TerminatorCore
import TerminatorFeatures
import TerminatorTestSupport

@MainActor
@Suite("Application model")
struct TerminatorAppModelTests {
    @Test("Replacing a credential retains the previous secret")
    func replacementRetainsOldSecret() async throws {
        let catalog = InMemoryTerminatorStore()
        let secrets = InMemorySecretStore()
        let model = TerminatorAppModel(
            capabilities: .direct,
            hostRepository: catalog,
            credentialRepository: catalog,
            historyRepository: catalog,
            secretStore: secrets,
            dockerService: MockDockerService(containers: [])
        )

        var draft = CredentialDraft()
        draft.label = "Deploy password"
        draft.secret = "old-secret"
        #expect(await model.saveCredential(draft))

        let original = try #require(model.credentials.first)
        #expect(await model.replaceCredentialSecret(id: original.id, with: "new-secret"))

        let replacement = try #require(model.credentials.first)
        #expect(replacement.secretID != original.secretID)
        #expect(try await secrets.read(id: original.secretID) == Data("old-secret".utf8))
        #expect(try await secrets.read(id: replacement.secretID) == Data("new-secret".utf8))
    }
}
