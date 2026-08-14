#if !APP_STORE
import CryptoKit
import Foundation
import TerminatorCore

actor MacOpenSSHIntegrationService: OpenSSHIntegrationService {
    private let sshDirectory: URL
    private let files: FileManager

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
                diagnostics.messages.append(AppL10n.text("openSSH.import.missingUser", alias))
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
        if files.fileExists(atPath: url.path), !replaceExisting { throw OpenSSHExportError.fileConflict(url) }
        try files.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: privateKey ? 0o600 : 0o644], ofItemAtPath: url.path)
    }

    private struct ConfigBlock {
        var patterns: [String]
        var directives: [(key: String, value: String)]
    }

    private func parseConfig(
        at url: URL, visited: inout Set<URL>, diagnostics: inout OpenSSHScanDiagnostics
    ) -> [ConfigBlock] {
        let canonical = url.standardizedFileURL
        guard visited.insert(canonical).inserted else {
            diagnostics.messages.append(AppL10n.text("openSSH.import.recursiveInclude", url.path))
            return []
        }
        guard let contents = try? String(contentsOf: canonical, encoding: .utf8) else { return [] }
        var blocks: [ConfigBlock] = [.init(patterns: ["*"], directives: [])]
        for rawLine in contents.components(separatedBy: .newlines) {
            let tokens = tokenize(rawLine)
            guard let name = tokens.first else { continue }
            let values = Array(tokens.dropFirst())
            switch name.lowercased() {
            case "host":
                guard !values.isEmpty else { diagnostics.malformedLines += 1; continue }
                blocks.append(.init(patterns: values, directives: []))
            case "include":
                for value in values {
                    for included in expandGlob(value, relativeTo: canonical) {
                        blocks.append(contentsOf: parseConfig(at: included, visited: &visited, diagnostics: &diagnostics))
                    }
                }
            case "hostname", "user", "port", "identityfile":
                guard let value = values.first else { diagnostics.malformedLines += 1; continue }
                blocks[blocks.count - 1].directives.append((name, value))
            case "match":
                diagnostics.unsupportedEntries += 1
            default:
                break
            }
        }
        return blocks
    }

    private func scanKeys(
        referencedBy hosts: [DiscoveredSSHHost], diagnostics: inout OpenSSHScanDiagnostics
    ) -> [DiscoveredAccessKey] {
        let referenced = hosts.flatMap(\.identityFiles)
        let directoryURLs = (try? files.contentsOfDirectory(
            at: sshDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        var candidates = orderedUnique(referenced + directoryURLs)
        candidates.removeAll { url in
            let name = url.lastPathComponent
            return name == "config" || name.hasPrefix("known_hosts") || name.hasSuffix(".pub") || name.hasPrefix("authorized_keys")
        }
        var result: [DiscoveredAccessKey] = []
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8), isPrivateKey(text) else {
                if directoryURLs.contains(url) { diagnostics.ignoredFiles += 1 }
                continue
            }
            let publicURL = URL(fileURLWithPath: url.path + ".pub")
            let publicText = (try? String(contentsOf: publicURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append(.init(
                label: url.lastPathComponent,
                privateKeyURL: url,
                publicKeyURL: publicText.isEmpty ? nil : publicURL,
                privateKey: text,
                publicKey: publicText,
                fingerprint: publicKeyFingerprint(publicText),
                isEncrypted: isEncryptedOpenSSHKey(text),
                importError: unsupportedImportReason(text)
            ))
        }
        return result
    }

    private func parseKnownHosts(
        at url: URL, candidateEndpoints: [String], diagnostics: inout OpenSSHScanDiagnostics
    ) -> [DiscoveredKnownHost] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [DiscoveredKnownHost] = []
        for rawLine in contents.components(separatedBy: .newlines) {
            let fields = rawLine.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard !fields.isEmpty, !fields[0].hasPrefix("#") else { continue }
            if fields[0].hasPrefix("@") { diagnostics.unsupportedEntries += 1; continue }
            guard fields.count >= 3, let blob = Data(base64Encoded: fields[2]) else {
                diagnostics.malformedLines += 1; continue
            }
            for token in fields[0].split(separator: ",").map(String.init) {
                guard let endpoint = resolvedKnownHostToken(token, candidates: candidateEndpoints) else { continue }
                result.append(.init(
                    endpoint: endpoint, algorithm: fields[1], publicKey: blob,
                    fingerprint: fingerprint(blob), sourceURL: url
                ))
            }
        }
        return result
    }

    private func resolvedKnownHostToken(_ token: String, candidates: [String]) -> String? {
        guard token.hasPrefix("|1|") else { return token }
        let parts = token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, let salt = Data(base64Encoded: String(parts[2])),
              let expected = Data(base64Encoded: String(parts[3])) else { return nil }
        return candidates.first { candidate in
            Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(candidate.utf8), using: SymmetricKey(data: salt))) == expected
        }
    }

    private func publicKeyFingerprint(_ line: String) -> String? {
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard fields.count >= 2, let data = Data(base64Encoded: String(fields[1])) else { return nil }
        return fingerprint(data)
    }

    private func fingerprint(_ data: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private func isPrivateKey(_ text: String) -> Bool {
        text.contains("-----BEGIN OPENSSH PRIVATE KEY-----")
            || text.contains("-----BEGIN RSA PRIVATE KEY-----")
            || text.contains("-----BEGIN EC PRIVATE KEY-----")
            || text.contains("-----BEGIN PRIVATE KEY-----")
    }

    private func isEncryptedOpenSSHKey(_ text: String) -> Bool {
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { return text.contains("ENCRYPTED PRIVATE KEY") }
        let payload = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("---") }.joined()
        guard let decoded = Data(base64Encoded: payload) else { return false }
        return decoded.range(of: Data("bcrypt".utf8)) != nil
    }

    private func unsupportedImportReason(_ text: String) -> String? {
        guard !text.contains("BEGIN OPENSSH PRIVATE KEY") else { return nil }
        let isEncryptedLegacy = text.contains("BEGIN ENCRYPTED PRIVATE KEY")
            || text.localizedCaseInsensitiveContains("Proc-Type: 4,ENCRYPTED")
        return isEncryptedLegacy
            ? "Encrypted legacy PEM and PKCS#8 keys are not supported. Convert the key to OpenSSH format first."
            : nil
    }

    private func tokenize(_ line: String) -> [String] {
        var result: [String] = [], current = "", quote: Character?
        for character in line {
            if character == "#", quote == nil { break }
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if character.isWhitespace, quote == nil {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func isConcreteAlias(_ value: String) -> Bool {
        !value.hasPrefix("!") && !value.contains("*") && !value.contains("?")
    }

    private func matches(_ value: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(escaped)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func matches(_ value: String, patterns: [String]) -> Bool {
        if patterns.contains(where: { $0.hasPrefix("!") && matches(value, pattern: String($0.dropFirst())) }) {
            return false
        }
        return patterns.contains { !$0.hasPrefix("!") && matches(value, pattern: $0) }
    }

    private func expandPath(_ path: String, relativeTo source: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return source.deletingLastPathComponent().appending(path: expanded).standardizedFileURL
    }

    private func expandGlob(_ pattern: String, relativeTo source: URL) -> [URL] {
        let url = expandPath(pattern, relativeTo: source)
        guard pattern.contains("*") || pattern.contains("?") else { return [url] }
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        return ((try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { matches($0.lastPathComponent, pattern: name) }
            .sorted { $0.path < $1.path }
    }

    private func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private func hostBlockRange(alias: String, lines: [String]) -> Range<Int>? {
        for index in lines.indices {
            let tokens = tokenize(lines[index])
            guard tokens.first?.lowercased() == "host", tokens.dropFirst().contains(alias) else { continue }
            var end = index + 1
            while end < lines.count {
                let next = tokenize(lines[end]).first?.lowercased()
                if next == "host" || next == "match" { break }
                end += 1
            }
            return index..<end
        }
        return nil
    }

    private func writeConfig(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else { throw OpenSSHExportError.invalidDestination }
        try data.write(to: url, options: .atomic)
        let current = (try? files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        if current == nil || current! & 0o077 != 0 {
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
#endif
