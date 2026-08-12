import Foundation
import Testing
import TerminatorCore
import TerminatorPersistence

@Suite("Persistent catalog", .serialized)
struct TerminatorStoreTests {
    @Test("Host mutations append immutable history and can be reverted")
    func hostHistoryAndRevert() async throws {
        let container = try TerminatorSchema.makeContainer(inMemory: true)
        let store = TerminatorStore(modelContainer: container)
        let original = HostProfile(displayName: "Production", hostname: "prod.example.com", username: "deploy")
        try await store.saveHost(original)

        var edited = original
        edited.hostname = "new.example.com"
        try await store.saveHost(edited)

        let historyBeforeRevert = try await store.listHistory(entity: .host)
        #expect(historyBeforeRevert.count == 2)
        #expect(historyBeforeRevert.first?.operation == .updated)

        let updateID = try #require(historyBeforeRevert.first?.id)
        try await store.revert(historyEntryID: updateID)

        let restored = try #require(try await store.host(id: original.id))
        #expect(restored.hostname == "prod.example.com")
        let historyAfterRevert = try await store.listHistory(entity: .host)
        #expect(historyAfterRevert.count == 3)
        #expect(historyAfterRevert.first?.operation == .restored)
    }

    @Test("Archiving a host retains its credential reference")
    func archiveRetainsCredential() async throws {
        let container = try TerminatorSchema.makeContainer(inMemory: true)
        let store = TerminatorStore(modelContainer: container)
        let credentialID = UUID()
        let host = HostProfile(
            displayName: "Lab",
            hostname: "lab.local",
            username: "admin",
            credentialID: credentialID
        )
        try await store.saveHost(host)
        try await store.deleteHost(id: host.id)

        let archived = try #require(try await store.host(id: host.id))
        #expect(archived.isDeleted)
        #expect(archived.credentialID == credentialID)
    }

    @Test("Credential history never contains secret bytes")
    func historyRedactsSecretBytes() async throws {
        let container = try TerminatorSchema.makeContainer(inMemory: true)
        let store = TerminatorStore(modelContainer: container)
        let credential = CredentialMetadata(label: "Deploy key", kind: .privateKey)
        try await store.saveCredential(credential)

        let entry = try #require(try await store.listHistory(entity: .credential).first)
        let snapshot = try #require(entry.afterSnapshot)
        let serialized = String(decoding: snapshot, as: UTF8.self)
        #expect(!serialized.contains("PRIVATE KEY"))
        #expect(serialized.contains(credential.secretID.description))
    }

    @Test("A secret purge history entry cannot be reverted")
    func purgeIsIrreversible() async throws {
        let container = try TerminatorSchema.makeContainer(inMemory: true)
        let store = TerminatorStore(modelContainer: container)
        var credential = CredentialMetadata(label: "Password", kind: .password)
        try await store.saveCredential(credential)
        credential.secretPurgedAt = .now
        try await store.saveCredential(credential)
        let purge = try #require(try await store.listHistory(entity: .credential).first)
        #expect(purge.operation == .purged)

        do {
            try await store.revert(historyEntryID: purge.id)
            Issue.record("Expected an irreversible purge error")
        } catch let error as PersistenceError {
            #expect(error == .secretPurgeIsIrreversible)
        }
    }

    @Test("Older history cannot make a purged secret appear available")
    func oldHistoryPreservesPurgeMarker() async throws {
        let container = try TerminatorSchema.makeContainer(inMemory: true)
        let store = TerminatorStore(modelContainer: container)
        var credential = CredentialMetadata(label: "Password", kind: .password)
        try await store.saveCredential(credential)
        credential.label = "Renamed password"
        try await store.saveCredential(credential)
        let update = try #require(try await store.listHistory(entity: .credential).first)
        credential.secretPurgedAt = .now
        try await store.saveCredential(credential)

        try await store.revert(historyEntryID: update.id)
        let restored = try #require(try await store.credential(id: credential.id))
        #expect(restored.secretPurgedAt != nil)
        #expect(!restored.isSecretAvailable)
    }
}
