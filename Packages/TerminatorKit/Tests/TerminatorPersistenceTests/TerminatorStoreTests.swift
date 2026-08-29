import Foundation
import SwiftData
import Testing
import TerminatorCore
@testable import TerminatorPersistence

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
        let legacyPassword = CredentialMetadata(id: credentialID, label: "Lab password", kind: .password)
        try await store.saveCredential(legacyPassword)
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
        #expect(archived.credentialID == nil)
        #expect(archived.authentication.authenticationMethods == [.password(secretID: legacyPassword.secretID)])
    }

    @Test("Credential history never contains secret bytes")
    func historyRedactsSecretBytes() async throws {
        let container = try TerminatorSchema.makeContainer(inMemory: true)
        let store = TerminatorStore(modelContainer: container)
        let secretID = SecretID()
        let credential = CredentialMetadata(
            label: "Deploy key",
            kind: .accessKey,
            secretID: secretID,
            accessKey: AccessKeyMetadata(
                algorithm: .ed25519,
                backend: .software,
                origin: .generated,
                publicKey: "ssh-ed25519 bW9jaw==",
                fingerprint: "SHA256:mock",
                privateMaterialID: secretID
            )
        )
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

    @Test("Identity references are validated and prevent destructive archive")
    func identityReferences() async throws {
        let container = try TerminatorSchema.makeContainer(inMemory: true)
        let store = TerminatorStore(modelContainer: container)
        let credential = CredentialMetadata(label: "Password", kind: .password)
        try await store.saveCredential(credential)
        let identity = IdentityProfile(name: "Production", username: "deploy", credentialIDs: [credential.id])
        try await store.saveIdentity(identity)
        let host = HostProfile(displayName: "Prod", hostname: "prod.example.com", authentication: .identity(identity.id))
        try await store.saveHost(host)

        await #expect(throws: PersistenceError.identityInUse) { try await store.deleteIdentity(id: identity.id) }
        await #expect(throws: PersistenceError.credentialInUse) { try await store.deleteCredential(id: credential.id) }
        let entries = try await store.listHistory(entity: .identity)
        #expect(entries.count == 1)
        #expect(entries.first?.schemaVersion == 3)
    }

    @Test("Versioned schema migrates a v1 host and key to v3")
    func migratesVersionOneStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TerminatorMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Terminator.store")
        let credentialID = UUID()
        let secretID = UUID()
        let hostID = UUID()

        do {
            let schema = Schema(versionedSchema: TerminatorSchemaV1.self)
            let configuration = ModelConfiguration("Terminator", schema: schema, url: storeURL, allowsSave: true)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(TerminatorSchemaV1.CredentialRecord(
                id: credentialID,
                label: "Legacy key",
                kindRawValue: "privateKey",
                secretID: secretID,
                fingerprint: nil,
                createdAt: .now,
                updatedAt: .now,
                deletedAt: nil,
                secretPurgedAt: nil
            ))
            context.insert(TerminatorSchemaV1.HostRecord(
                id: hostID,
                displayName: "Legacy host",
                hostname: "legacy.example.com",
                port: 22,
                username: "deploy",
                group: nil,
                tags: [],
                notes: "",
                credentialID: credentialID,
                createdAt: .now,
                updatedAt: .now,
                deletedAt: nil
            ))
            try context.save()
        }

        let schema = Schema(versionedSchema: TerminatorSchemaV3.self)
        let configuration = ModelConfiguration("Terminator", schema: schema, url: storeURL, allowsSave: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: TerminatorMigrationPlan.self,
            configurations: [configuration]
        )
        let store = TerminatorStore(modelContainer: container)
        let host = try #require(try await store.host(id: hostID))
        let credential = try #require(try await store.credential(id: credentialID))
        #expect(host.authentication == .manual(
            username: "deploy",
            authenticationMethods: [.accessKey(credentialID: credentialID)]
        ))
        #expect(credential.kind == .accessKey)
        #expect(credential.accessKey?.compatibility == .needsUpgrade)
        #expect(credential.accessKey?.privateMaterialID.rawValue == secretID)
    }

    @Test("Known hosts retain multiple algorithms for one endpoint")
    func multipleKnownHostAlgorithms() async throws {
        let container = try TerminatorSchema.makeContainer(inMemory: true)
        let store = TerminatorStore(modelContainer: container)
        let endpoint = "server.example.com"
        try await store.saveKnownHost(.init(
            endpoint: endpoint, algorithm: "ssh-ed25519", publicKey: Data([1]), fingerprint: "SHA256:one"
        ))
        try await store.saveKnownHost(.init(
            endpoint: endpoint, algorithm: "rsa-sha2-512", publicKey: Data([2]), fingerprint: "SHA256:two"
        ))

        #expect(try await store.knownHosts(endpoint: endpoint).count == 2)
        #expect(try await store.knownHost(endpoint: endpoint, algorithm: "ssh-ed25519")?.fingerprint == "SHA256:one")
        try await store.removeKnownHost(endpoint: endpoint, algorithm: "ssh-ed25519")
        #expect(try await store.knownHosts(endpoint: endpoint).map(\.algorithm) == ["rsa-sha2-512"])
    }

    @Test("Versioned schema migrates the single-key V4 known host to V5")
    func migratesVersionFourKnownHost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TerminatorV4Migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Terminator.store")
        let endpoint = "legacy.example.com"

        do {
            let schema = Schema(versionedSchema: TerminatorSchemaV4.self)
            let configuration = ModelConfiguration("Terminator", schema: schema, url: storeURL, allowsSave: true)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(TerminatorSchemaV4.KnownHostRecord(
                endpoint: endpoint, id: UUID(), algorithm: "ssh-ed25519",
                publicKey: Data([1, 2, 3]), fingerprint: "SHA256:legacy",
                createdAt: .now, updatedAt: .now
            ))
            try context.save()
        }

        let schema = Schema(versionedSchema: TerminatorSchemaV5.self)
        let configuration = ModelConfiguration("Terminator", schema: schema, url: storeURL, allowsSave: true)
        let container = try ModelContainer(
            for: schema, migrationPlan: TerminatorMigrationPlan.self, configurations: [configuration]
        )
        let store = TerminatorStore(modelContainer: container)
        #expect(try await store.knownHost(endpoint: endpoint, algorithm: "ssh-ed25519")?.fingerprint == "SHA256:legacy")

        try await store.saveKnownHost(.init(
            endpoint: endpoint, algorithm: "rsa-sha2-512", publicKey: Data([4]), fingerprint: "SHA256:new"
        ))
        #expect(try await store.knownHosts(endpoint: endpoint).count == 2)
    }

    @Test("Inferred schema opens a store after new host columns")
    func inferredSchemaOpensCopiedApplicationStore() async throws {
        let original = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Terminator.store")
        guard FileManager.default.fileExists(atPath: original.path) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TerminatorUserStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appending(path: "Terminator.store")
        try FileManager.default.copyItem(at: original, to: copy)
        for suffix in ["-wal", "-shm"] {
            let extra = URL(fileURLWithPath: original.path + suffix)
            if FileManager.default.fileExists(atPath: extra.path) {
                try FileManager.default.copyItem(at: extra, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        let schema = Schema(TerminatorSchema.currentModels)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Terminator", schema: schema, url: copy, allowsSave: true)]
        )
        let store = TerminatorStore(modelContainer: container)
        _ = try await store.listHosts(includeDeleted: true)
    }

    @Test("Versioned schema migrates v2 password references into embedded methods")
    func migratesVersionTwoStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TerminatorMigrationV2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Terminator.store")
        let passwordID = UUID()
        let passwordSecretID = UUID()
        let identityID = UUID()
        let hostID = UUID()

        do {
            let schema = Schema(versionedSchema: TerminatorSchemaV2.self)
            let configuration = ModelConfiguration("Terminator", schema: schema, url: storeURL, allowsSave: true)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)

            let password = TerminatorSchemaV2.CredentialRecord()
            password.id = passwordID
            password.label = "Legacy password"
            password.kindRawValue = "password"
            password.secretID = passwordSecretID
            context.insert(password)

            let identity = TerminatorSchemaV2.IdentityRecord()
            identity.id = identityID
            identity.name = "Legacy identity"
            identity.username = "deploy"
            identity.credentialIDs = [passwordID]
            context.insert(identity)

            let host = TerminatorSchemaV2.HostRecord()
            host.id = hostID
            host.displayName = "Legacy manual host"
            host.hostname = "legacy.example.com"
            host.username = "root"
            host.credentialIDs = [passwordID]
            context.insert(host)
            try context.save()
        }

        let schema = Schema(versionedSchema: TerminatorSchemaV3.self)
        let configuration = ModelConfiguration("Terminator", schema: schema, url: storeURL, allowsSave: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: TerminatorMigrationPlan.self,
            configurations: [configuration]
        )
        let store = TerminatorStore(modelContainer: container)
        let identity = try #require(try await store.identity(id: identityID))
        let host = try #require(try await store.host(id: hostID))

        #expect(identity.authenticationMethods == [.password(secretID: SecretID(rawValue: passwordSecretID))])
        #expect(host.authentication == .manual(
            username: "root",
            authenticationMethods: [.password(secretID: SecretID(rawValue: passwordSecretID))]
        ))
    }
}
