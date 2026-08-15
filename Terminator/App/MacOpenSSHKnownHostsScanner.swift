#if !APP_STORE
import CryptoKit
import Foundation
import TerminatorCore

extension MacOpenSSHIntegrationService {
    func parseKnownHosts(
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

    func resolvedKnownHostToken(_ token: String, candidates: [String]) -> String? {
        guard token.hasPrefix("|1|") else { return token }
        let parts = token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, let salt = Data(base64Encoded: String(parts[2])),
              let expected = Data(base64Encoded: String(parts[3])) else { return nil }
        return candidates.first { candidate in
            Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(candidate.utf8), using: SymmetricKey(data: salt))) == expected
        }
    }

}
#endif
