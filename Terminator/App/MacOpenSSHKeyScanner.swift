#if !APP_STORE
import CryptoKit
import Foundation
import TerminatorCore

extension MacOpenSSHIntegrationService {
    func scanKeys(
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

    func publicKeyFingerprint(_ line: String) -> String? {
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard fields.count >= 2, let data = Data(base64Encoded: String(fields[1])) else { return nil }
        return fingerprint(data)
    }

    func fingerprint(_ data: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    func isPrivateKey(_ text: String) -> Bool {
        text.contains("-----BEGIN OPENSSH PRIVATE KEY-----")
            || text.contains("-----BEGIN RSA PRIVATE KEY-----")
            || text.contains("-----BEGIN EC PRIVATE KEY-----")
            || text.contains("-----BEGIN PRIVATE KEY-----")
    }

    func isEncryptedOpenSSHKey(_ text: String) -> Bool {
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { return text.contains("ENCRYPTED PRIVATE KEY") }
        let payload = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("---") }.joined()
        guard let decoded = Data(base64Encoded: payload) else { return false }
        return decoded.range(of: Data("bcrypt".utf8)) != nil
    }

    func unsupportedImportReason(_ text: String) -> String? {
        guard !text.contains("BEGIN OPENSSH PRIVATE KEY") else { return nil }
        let isEncryptedLegacy = text.contains("BEGIN ENCRYPTED PRIVATE KEY")
            || text.localizedCaseInsensitiveContains("Proc-Type: 4,ENCRYPTED")
        return isEncryptedLegacy
            ? AppL10n.text(.openSSHEncryptedLegacyUnsupported)
            : nil
    }

}
#endif
