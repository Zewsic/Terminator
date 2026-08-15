#if !APP_STORE
import CryptoKit
import Foundation
import TerminatorCore

actor MacOpenSSHIntegrationService: OpenSSHIntegrationService {
    let sshDirectory: URL
    let files: FileManager

    init(
        sshDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh", directoryHint: .isDirectory),
        files: FileManager = .default
    ) {
        self.sshDirectory = sshDirectory
        self.files = files
    }

    func scan(knownEndpoints: [String]) throws -> OpenSSHDiscoverySnapshot {
        var diagnostics = OpenSSHScanDiagnostics()
        let configURL = sshDirectory.appending(path: "config")
        var visited = Set<URL>()
        let blocks = parseConfig(at: configURL, visited: &visited, diagnostics: &diagnostics)
        let aliases = orderedUnique(blocks.flatMap(\.patterns).filter(isConcreteAlias))
        var hosts: [DiscoveredSSHHost] = []

        for alias in aliases {
            var values: [String: [String]] = [:]
            for block in blocks where matches(alias, patterns: block.patterns) {
                for directive in block.directives {
                    let key = directive.key.lowercased()
                    if key == "identityfile" {
                        values[key, default: []].append(directive.value)
                    } else if values[key] == nil {
                        values[key] = [directive.value]
                    }
                }
            }
            let hostname = values["hostname"]?.first ?? alias
            let username = values["user"]?.first ?? ""
            guard !username.isEmpty else {
                diagnostics.unsupportedEntries += 1
                diagnostics.messages.append(AppL10n.text(.opensshImportMissingUser, alias))
                continue
            }
            let port = Int(values["port"]?.first ?? "22") ?? 22
            let identities = orderedUnique((values["identityfile"] ?? []).map { expandPath($0, relativeTo: configURL) })
            hosts.append(.init(
                alias: alias, hostname: hostname, port: port, username: username,
                identityFiles: identities, sourceURL: configURL
            ))
        }

        let keys = scanKeys(referencedBy: hosts, diagnostics: &diagnostics)
        let endpoints = orderedUnique(knownEndpoints + hosts.flatMap { host in
            [host.endpoint, host.hostname, host.port == 22 ? host.hostname : "[\(host.hostname)]:\(host.port)"]
        })
        let trusted = parseKnownHosts(
            at: sshDirectory.appending(path: "known_hosts"),
            candidateEndpoints: endpoints,
            diagnostics: &diagnostics
        )
        return .init(
            hosts: hosts.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending },
            accessKeys: keys.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending },
            knownHosts: trusted.sorted { $0.endpoint < $1.endpoint },
            diagnostics: diagnostics
        )
    }

    func hostBlock(for request: OpenSSHHostExportRequest) -> String {
        var lines = [
            "Host \(request.alias)",
            "    HostName \(request.hostname)",
            "    User \(request.username)",
        ]
        if request.port != 22 { lines.append("    Port \(request.port)") }
        lines.append(contentsOf: request.identityFiles.map { "    IdentityFile \($0.path)" })
        return lines.joined(separator: "\n") + "\n"
    }

    func comparison(for request: OpenSSHHostExportRequest) throws -> OpenSSHHostExportComparison? {
        let existing = (try? String(contentsOf: request.configURL, encoding: .utf8)) ?? ""
        let lines = existing.components(separatedBy: .newlines)
        guard let range = hostBlockRange(alias: request.alias, lines: lines) else { return nil }
        return .init(
            existingBlock: lines[range].joined(separator: "\n") + "\n",
            proposedBlock: hostBlock(for: request)
        )
    }

    func exportHost(_ request: OpenSSHHostExportRequest) throws {
        let directory = request.configURL.deletingLastPathComponent()
        guard !request.alias.isEmpty, !request.alias.contains(where: \.isWhitespace),
              !request.hostname.isEmpty, !request.username.isEmpty else {
            throw OpenSSHExportError.invalidDestination
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let proposed = hostBlock(for: request)
        let existing = (try? String(contentsOf: request.configURL, encoding: .utf8)) ?? ""
        let lines = existing.components(separatedBy: .newlines)
        if let range = hostBlockRange(alias: request.alias, lines: lines) {
            let old = lines[range].joined(separator: "\n") + "\n"
            guard request.replaceExisting else {
                throw OpenSSHExportError.aliasConflict(existingBlock: old, proposedBlock: proposed)
            }
            var updated = lines
            updated.replaceSubrange(range, with: proposed.trimmingCharacters(in: .newlines).components(separatedBy: "\n"))
            try writeConfig(updated.joined(separator: "\n"), to: request.configURL)
        } else {
            let separator = existing.isEmpty || existing.hasSuffix("\n\n") ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
            try writeConfig(existing + separator + proposed, to: request.configURL)
        }
    }

    func writeKey(_ data: Data, to url: URL, privateKey: Bool, replaceExisting: Bool) throws {
        guard url.lastPathComponent == OpenSSHPathPolicy.safeFilename(url.lastPathComponent) else {
            throw OpenSSHExportError.invalidDestination
        }
        if files.fileExists(atPath: url.path), !replaceExisting { throw OpenSSHExportError.fileConflict(url) }
        try files.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: privateKey ? 0o600 : 0o644], ofItemAtPath: url.path)
    }

}
#endif
