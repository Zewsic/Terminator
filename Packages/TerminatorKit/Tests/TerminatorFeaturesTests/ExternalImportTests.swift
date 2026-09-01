import Foundation
import Testing
import TerminatorCore
import TerminatorFeatures
import TerminatorTestSupport

@MainActor
@Suite("External import")
struct ExternalImportTests {
    @Test("Loading a source only stages entities in memory")
    func loadingDoesNotPersistAnything() async throws {
        let source = ExternalImportSource(kind: .termiusDirect, displayName: "Termius Direct")
        let bundle = fixtureBundle(source: source)
        let service = MockExternalImportService(sources: [source], bundles: [source.id: bundle])
        let (model, _) = makeModel(externalImportService: service)

        await model.load()
        #expect(model.availableImportSources == [source])
        #expect(model.hosts.isEmpty)
        #expect(model.identities.isEmpty)
        #expect(model.credentials.isEmpty)

        await model.loadImportSource(source)

        #expect(model.availableImportSources.isEmpty)
        #expect(model.externalImportBundles[source.id] == bundle)
        #expect(model.hosts.isEmpty)
        #expect(model.identities.isEmpty)
        #expect(model.credentials.isEmpty)
        #expect(await service.scanCount() == 1)
    }

    @Test("Importing a staged host also imports its identity and access key")
    func hostImportCascadesLinkedAuthentication() async throws {
        let source = ExternalImportSource(kind: .termiusDirect, displayName: "Termius Direct")
        let bundle = fixtureBundle(source: source)
        let service = MockExternalImportService(sources: [source], bundles: [source.id: bundle])
        let (model, _) = makeModel(externalImportService: service)
        await model.load()
        await model.loadImportSource(source)

        let host = try #require(bundle.hosts.first)
        let saved = await model.importExternalHost(
            host,
            from: bundle,
            editedDraft: model.externalHostDraft(host, in: bundle)
        )

        #expect(saved)
        let persistedHost = try #require(model.hosts.first)
        let identityID = try #require(persistedHost.authentication.identityID)
        let identity = try #require(model.identities.first { $0.id == identityID })
        let credentialID = try #require(identity.authenticationMethods.compactMap(\.credentialID).first)
        #expect(model.credentials.contains { $0.id == credentialID })
        #expect(model.externalImportBundles[source.id]?.hosts.isEmpty == true)
        #expect(model.externalImportBundles[source.id]?.identities.isEmpty == true)
        #expect(model.externalImportBundles[source.id]?.accessKeys.isEmpty == true)
    }

    private func makeModel(
        externalImportService: any ExternalImportService
    ) -> (TerminatorAppModel, InMemoryTerminatorStore) {
        let store = InMemoryTerminatorStore()
        return (
            TerminatorAppModel(
                capabilities: .direct,
                hostRepository: store,
                credentialRepository: store,
                identityRepository: store,
                historyRepository: store,
                secretStore: InMemorySecretStore(),
                accessKeyService: MockAccessKeyService(),
                userPresenceAuthorizer: AllowingUserPresenceAuthorizer(),
                dockerService: MockDockerService(containers: []),
                externalImportService: externalImportService
            ),
            store
        )
    }

    private func fixtureBundle(source: ExternalImportSource) -> ExternalImportBundle {
        let key = ExternalImportAccessKey(id: "key", label: "Deploy", privateKey: "private")
        let identity = ExternalImportIdentity(
            id: "identity", label: "Production", username: "deploy", password: "secret",
            accessKeyIDs: [key.id]
        )
        let host = ExternalImportHost(
            id: "host", label: "API", hostname: "api.example.com", group: "Production",
            tags: ["api"], identityID: identity.id, accessKeyID: key.id,
            proxyID: "proxy", tunnelIDs: ["tunnel"]
        )
        return ExternalImportBundle(
            source: source,
            hosts: [host], identities: [identity], accessKeys: [key],
            tunnels: [.init(id: "tunnel", hostID: host.id, label: "Database", kind: .local, localPort: 5432, targetHost: "db", targetPort: 5432)],
            proxies: [.init(id: "proxy", kind: "http", hostname: "proxy.example.com", port: 8080)],
            knownHosts: [.init(id: "known", hostnames: "api.example.com", key: "ssh-ed25519 AAAA")]
        )
    }
}

private actor MockExternalImportService: ExternalImportService {
    let sources: [ExternalImportSource]
    let bundles: [String: ExternalImportBundle]
    private var scans = 0

    init(sources: [ExternalImportSource], bundles: [String: ExternalImportBundle]) {
        self.sources = sources
        self.bundles = bundles
    }

    func availableSources() -> [ExternalImportSource] { sources }

    func scan(_ source: ExternalImportSource) throws -> ExternalImportBundle {
        scans += 1
        guard let bundle = bundles[source.id] else { throw MockExternalImportError.missingBundle }
        return bundle
    }

    func scanCount() -> Int { scans }
}

private enum MockExternalImportError: Error { case missingBundle }
