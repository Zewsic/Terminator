import Foundation
import Testing
import TerminatorCore
@testable import TerminatorFeatures

@Suite("Secret mutation journal")
struct SecretMutationJournalTests {
    @Test("Created secrets are removed when metadata persistence fails")
    func rollbackCreatedSecrets() async throws {
        let store = FaultInjectingSecretStore()
        var journal = SecretMutationJournal(secretStore: store)
        let id = try await journal.create(Data("new".utf8))

        await journal.rollbackCreatedSecrets()

        await #expect(throws: FaultInjectingSecretStore.Failure.notFound) {
            try await store.read(id: id)
        }
    }

    @Test("Only successfully purged secrets are restored after a partial purge")
    func restorePartialPurge() async throws {
        let first = SecretID()
        let second = SecretID()
        let store = FaultInjectingSecretStore(failPurgeAt: 2)
        try await store.store(Data("one".utf8), for: first, access: .deviceOnly)
        try await store.store(Data("two".utf8), for: second, access: .deviceOnly)
        var journal = SecretMutationJournal(secretStore: store)
        try await journal.backUp([first, second])

        do {
            try await journal.purgeBackedUpSecrets()
            Issue.record("Expected the injected purge failure")
        } catch {}
        await journal.restorePurgedSecrets()

        #expect(try await store.read(id: first) == Data("one".utf8))
        #expect(try await store.read(id: second) == Data("two".utf8))
    }
}

private actor FaultInjectingSecretStore: SecretStore {
    enum Failure: Error, Equatable { case duplicate, notFound, purge }

    private var values: [SecretID: Data] = [:]
    private let failPurgeAt: Int?
    private var purgeCount = 0

    init(failPurgeAt: Int? = nil) {
        self.failPurgeAt = failPurgeAt
    }

    func store(_ secret: Data, for id: SecretID, access: SecretAccessPolicy) throws {
        guard values[id] == nil else { throw Failure.duplicate }
        values[id] = secret
    }

    func read(id: SecretID) throws -> Data {
        guard let value = values[id] else { throw Failure.notFound }
        return value
    }

    func purge(id: SecretID) throws {
        purgeCount += 1
        if purgeCount == failPurgeAt { throw Failure.purge }
        values[id] = nil
    }
}
