import Foundation
import Observation
import TerminatorCore

extension TerminatorAppModel {
    public func refreshOpenSSH() async {
        guard capabilities.externalFileAccess, let openSSHService else { return }
        isScanningOpenSSH = true
        defer { isScanningOpenSSH = false }
        do {
            let endpoints = hosts.map { $0.port == 22 ? $0.hostname : "[\($0.hostname)]:\($0.port)" }
            var snapshot = try await openSSHService.scan(knownEndpoints: endpoints)
            for index in snapshot.accessKeys.indices
            where snapshot.accessKeys[index].fingerprint == nil && !snapshot.accessKeys[index].isEncrypted {
                if let prepared = try? await accessKeyService.importSoftwareKey(.init(
                    privateKey: snapshot.accessKeys[index].privateKey,
                    suppliedPublicKey: snapshot.accessKeys[index].publicKey
                )) {
                    snapshot.accessKeys[index].fingerprint = prepared.fingerprint
                    snapshot.accessKeys[index].publicKey = prepared.publicKey
                }
            }
            for index in snapshot.hosts.indices {
                snapshot.hosts[index].status = matchingHost(for: snapshot.hosts[index]) == nil ? .available : .existing
            }
            for index in snapshot.accessKeys.indices {
                if let fingerprint = snapshot.accessKeys[index].fingerprint,
                   credentials.contains(where: { $0.accessKey?.fingerprint == fingerprint && !$0.isDeleted }) {
                    snapshot.accessKeys[index].status = .existing
                }
            }
            if let knownHostRepository {
                for index in snapshot.knownHosts.indices {
                    let item = snapshot.knownHosts[index]
                    let stored = try await knownHostRepository.knownHost(endpoint: item.endpoint, algorithm: item.algorithm)
                    if stored == nil {
                        try await knownHostRepository.saveKnownHost(.init(
                            endpoint: item.endpoint,
                            algorithm: item.algorithm,
                            publicKey: item.publicKey,
                            fingerprint: item.fingerprint
                        ))
                        snapshot.knownHosts[index].status = .existing
                    } else {
                        snapshot.knownHosts[index].status = stored?.publicKey == item.publicKey ? .existing : .changed
                    }
                }
            }
            openSSH = snapshot
        } catch { present(error) }
    }

    public func matchingHost(for discovered: DiscoveredSSHHost) -> HostProfile? {
        hosts.first { host in
            host.hostname.normalizedSSHEndpoint == discovered.hostname.normalizedSSHEndpoint
                && host.port == discovered.port
                && resolvedUsername(for: host).caseInsensitiveCompare(discovered.username) == .orderedSame
        }
    }

    public func discoveredKey(at url: URL) -> DiscoveredAccessKey? {
        openSSH.accessKeys.first { $0.privateKeyURL.standardizedFileURL == url.standardizedFileURL }
    }

    public func draft(for discovered: DiscoveredAccessKey) -> AccessKeyDraft {
        var draft = AccessKeyDraft()
        draft.label = discovered.label
        draft.mode = .importExisting
        draft.privateKey = discovered.privateKey
        draft.publicKey = discovered.publicKey
        return draft
    }

    public func importKnownHost(_ discovered: DiscoveredKnownHost, replaceChanged: Bool = false) async -> Bool {
        guard let knownHostRepository else { return false }
        do {
            if let stored = try await knownHostRepository.knownHost(
                endpoint: discovered.endpoint, algorithm: discovered.algorithm
            ), stored.publicKey != discovered.publicKey, !replaceChanged {
                present(id: "stored-host-key-differs", message: FeatureL10n.text(.errorStoredHostKeyDiffers))
                return false
            }
            let previous = try await knownHostRepository.knownHost(
                endpoint: discovered.endpoint, algorithm: discovered.algorithm
            )
            try await knownHostRepository.saveKnownHost(.init(
                id: previous?.id ?? UUID(), endpoint: discovered.endpoint,
                algorithm: discovered.algorithm, publicKey: discovered.publicKey,
                fingerprint: discovered.fingerprint, createdAt: previous?.createdAt ?? .now
            ))
            openSSHResultMessage = previous == nil ? "Trusted host imported." : "Trusted host updated."
            await refreshOpenSSH()
            return true
        } catch { present(error); return false }
    }

    public func importHost(_ discovered: DiscoveredSSHHost, credentialIDs: [UUID]) async -> Bool {
        let existing = matchingHost(for: discovered)
        var methods = existing?.authentication.authenticationMethods ?? []
        if let identityID = existing?.authentication.identityID,
           let identity = identities.first(where: { $0.id == identityID }) {
            methods = identity.authenticationMethods
        }
        for id in credentialIDs where !methods.contains(.accessKey(credentialID: id)) {
            methods.append(.accessKey(credentialID: id))
        }
        var draft = HostDraft()
        draft.id = existing?.id
        draft.displayName = discovered.alias
        draft.hostname = discovered.hostname
        draft.port = discovered.port
        draft.usesIdentity = false
        draft.username = discovered.username
        draft.authenticationMethods = methods.map { method in
            switch method {
            case .password(let secretID):
                IdentityDraftMethod(kind: .password(existingSecretID: secretID))
            case .accessKey(let credentialID):
                IdentityDraftMethod(kind: .accessKey(credentialID))
            }
        }
        draft.group = existing?.group ?? ""
        draft.tagsText = existing?.tags.joined(separator: ", ") ?? ""
        draft.notes = existing?.notes ?? ""
        let saved = await saveHost(draft)
        if saved {
            if !suppressesImportAnnouncements {
                openSSHResultMessage = existing == nil ? "Host imported." : "Host updated from OpenSSH."
            }
            await refreshOpenSSH()
        }
        return saved
    }

    public func hostExportRequest(
        for host: HostProfile, configURL: URL, keyURLs: [URL], replaceExisting: Bool
    ) -> OpenSSHHostExportRequest {
        .init(
            alias: host.displayName.replacingOccurrences(of: " ", with: "-"),
            hostname: host.hostname, port: host.port, username: resolvedUsername(for: host),
            identityFiles: keyURLs, configURL: configURL, replaceExisting: replaceExisting
        )
    }

    public func previewOpenSSHExport(_ request: OpenSSHHostExportRequest) async -> String {
        await openSSHService?.hostBlock(for: request) ?? ""
    }

    public func compareOpenSSHExport(_ request: OpenSSHHostExportRequest) async -> OpenSSHHostExportComparison? {
        do { return try await openSSHService?.comparison(for: request) }
        catch { present(error); return nil }
    }

    public func exportHostToOpenSSH(
        _ request: OpenSSHHostExportRequest,
        keyExports: [(credentialID: UUID, privateURL: URL?, publicURL: URL?)],
        replaceFiles: Bool,
        passphrases: [UUID: String] = [:]
    ) async -> Bool {
        guard let openSSHService else { return false }
        do {
            for item in keyExports {
                guard let credential = credentials.first(where: { $0.id == item.credentialID }),
                      let key = credential.accessKey else { continue }
                if let publicURL = item.publicURL, let publicData = (key.publicKey + "\n").data(using: .utf8) {
                    try await openSSHService.writeKey(publicData, to: publicURL, privateKey: false, replaceExisting: replaceFiles)
                }
                if let privateURL = item.privateURL {
                    guard let data = await exportPrivateKey(
                        id: credential.id, passphrase: passphrases[credential.id] ?? ""
                    ) else { return false }
                    try await openSSHService.writeKey(data, to: privateURL, privateKey: true, replaceExisting: replaceFiles)
                }
            }
            try await openSSHService.exportHost(request)
            await refreshOpenSSH()
            return true
        } catch { present(error); return false }
    }

}
