import Foundation
import Testing
import TerminatorCore
import TerminatorSecurity

@Suite("Keychain secret store", .serialized)
struct KeychainSecretStoreTests {
    @Test("Stores, reads, and purges an isolated secret")
    func lifecycle() async throws {
        let service = "pro.zewsic.terminator.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let id = SecretID()
        let value = Data("integration-secret".utf8)

        try await store.store(value, for: id)
        let restored = try await store.read(id: id)
        #expect(restored == value)
        try await store.purge(id: id)

        do {
            _ = try await store.read(id: id)
            Issue.record("Expected the purged secret to be unavailable")
        } catch let error as KeychainSecretStoreError {
            #expect(error == .secretNotFound)
        }
    }
}
