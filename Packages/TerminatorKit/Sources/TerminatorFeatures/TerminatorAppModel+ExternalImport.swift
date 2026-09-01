import Foundation
import TerminatorCore

extension TerminatorAppModel {
    public var availableImportSources: [ExternalImportSource] {
        importSources.filter { !loadedImportSourceIDs.contains($0.id) }
    }

    public var loadedExternalImportBundles: [ExternalImportBundle] {
        importSources.compactMap { externalImportBundles[$0.id] }
    }

    public func refreshImportSources() async {
        guard capabilities.externalFileAccess else { return }
        var sources: [ExternalImportSource] = []
        if openSSHService != nil {
            sources.append(.init(kind: .openSSH, displayName: "OpenSSH"))
        }
        if let externalImportService {
            sources.append(contentsOf: await externalImportService.availableSources())
        }
        importSources = sources
        let validIDs = Set(sources.map(\.id))
        loadedImportSourceIDs.formIntersection(validIDs)
        externalImportBundles = externalImportBundles.filter { validIDs.contains($0.key) }
    }

    public func loadImportSource(_ source: ExternalImportSource) async {
        guard !loadingImportSourceIDs.contains(source.id) else { return }
        loadingImportSourceIDs.insert(source.id)
        defer { loadingImportSourceIDs.remove(source.id) }
        switch source.kind {
        case .openSSH:
            await refreshOpenSSH()
            loadedImportSourceIDs.insert(source.id)
        case .termiusDirect, .termiusAppStore:
            guard let externalImportService else { return }
            do {
                externalImportBundles[source.id] = try await externalImportService.scan(source)
                loadedImportSourceIDs.insert(source.id)
            } catch {
                present(error)
            }
        }
    }

    public func externalAccessKeyDraft(_ key: ExternalImportAccessKey) -> AccessKeyDraft {
        var draft = AccessKeyDraft()
        draft.label = key.label
        draft.mode = .importExisting
        draft.privateKey = key.privateKey
        draft.publicKey = key.publicKey
        draft.passphrase = key.passphrase
        draft.passphraseConfirmation = key.passphrase
        draft.savePassphrase = !key.passphrase.isEmpty
        return draft
    }

    public func externalIdentityDraft(_ identity: ExternalImportIdentity) -> IdentityDraft {
        var draft = IdentityDraft()
        draft.name = identity.label.isEmpty ? identity.username : identity.label
        draft.username = identity.username
        if let index = draft.authenticationMethods.firstIndex(where: { method in
            if case .password = method.kind { return true }
            return false
        }), !identity.password.isEmpty {
            draft.authenticationMethods[index].password = identity.password
            draft.authenticationMethods[index].passwordChanged = true
        }
        return draft
    }

    public func externalHostDraft(_ host: ExternalImportHost, in bundle: ExternalImportBundle) -> HostDraft {
        let identity = host.identityID.flatMap { id in bundle.identities.first { $0.id == id } }
        var draft = HostDraft()
        draft.displayName = host.label
        draft.hostname = host.hostname
        draft.port = host.port
        draft.group = host.group
        draft.tagsText = host.tags.joined(separator: ", ")
        draft.usesIdentity = false
        draft.username = identity?.username ?? ""
        if let password = identity?.password, !password.isEmpty,
           let index = draft.authenticationMethods.firstIndex(where: { method in
               if case .password = method.kind { return true }
               return false
           }) {
            draft.authenticationMethods[index].password = password
            draft.authenticationMethods[index].passwordChanged = true
        }
        return draft
    }

    public func importExternalIdentity(
        _ identity: ExternalImportIdentity,
        from bundle: ExternalImportBundle,
        editedDraft: IdentityDraft,
        consumeAfterSave: Bool = true
    ) async -> UUID? {
        var credentialIDs: [UUID] = []
        for keyID in identity.accessKeyIDs {
            guard let key = bundle.accessKeys.first(where: { $0.id == keyID }) else { continue }
            guard let id = await saveAccessKey(externalAccessKeyDraft(key)) else { return nil }
            credentialIDs.append(id)
        }
        var draft = editedDraft
        draft.authenticationMethods.removeAll { method in
            if case .accessKey = method.kind { return true }
            return false
        }
        draft.authenticationMethods.append(contentsOf: credentialIDs.map { IdentityDraftMethod(kind: .accessKey($0)) })
        guard await saveIdentity(draft) else { return nil }
        let savedID = activeIdentities
            .filter { $0.name == draft.name && $0.username == draft.username }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?.id
        if consumeAfterSave { consumeExternalIdentity(identity, sourceID: bundle.source.id) }
        return savedID
    }

    public func importExternalHost(
        _ host: ExternalImportHost, from bundle: ExternalImportBundle, editedDraft: HostDraft
    ) async -> Bool {
        var draft = editedDraft
        var importedIdentity: ExternalImportIdentity?
        var importedAccessKey: ExternalImportAccessKey?
        if let identityID = host.identityID,
           let identity = bundle.identities.first(where: { $0.id == identityID }) {
            guard let localID = await importExternalIdentity(
                identity,
                from: bundle,
                editedDraft: externalIdentityDraft(identity),
                consumeAfterSave: false
            ) else { return false }
            draft.usesIdentity = true
            draft.identityID = localID
            draft.authenticationMethods = []
            importedIdentity = identity
        } else if let keyID = host.accessKeyID,
                  let key = bundle.accessKeys.first(where: { $0.id == keyID }) {
            guard let localID = await saveAccessKey(externalAccessKeyDraft(key)) else { return false }
            draft.authenticationMethods.append(.init(kind: .accessKey(localID)))
            importedAccessKey = key
        }
        let saved = await saveHost(draft)
        if saved {
            if let importedIdentity { consumeExternalIdentity(importedIdentity, sourceID: bundle.source.id) }
            if let importedAccessKey { consumeExternalAccessKey(importedAccessKey, sourceID: bundle.source.id) }
            consumeExternalHost(host, sourceID: bundle.source.id)
        }
        return saved
    }

    public func consumeExternalAccessKey(_ key: ExternalImportAccessKey, sourceID: String) {
        guard var bundle = externalImportBundles[sourceID] else { return }
        bundle.accessKeys.removeAll { $0.id == key.id }
        externalImportBundles[sourceID] = bundle
    }

    private func consumeExternalIdentity(_ identity: ExternalImportIdentity, sourceID: String) {
        guard var bundle = externalImportBundles[sourceID] else { return }
        bundle.identities.removeAll { $0.id == identity.id }
        bundle.accessKeys.removeAll { identity.accessKeyIDs.contains($0.id) }
        externalImportBundles[sourceID] = bundle
    }

    private func consumeExternalHost(_ host: ExternalImportHost, sourceID: String) {
        guard var bundle = externalImportBundles[sourceID] else { return }
        bundle.hosts.removeAll { $0.id == host.id }
        externalImportBundles[sourceID] = bundle
    }
}
