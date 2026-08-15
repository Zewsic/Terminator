#if !APP_STORE
import CryptoKit
import Foundation
import TerminatorCore

extension MacOpenSSHIntegrationService {
    func hostBlockRange(alias: String, lines: [String]) -> Range<Int>? {
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

    func writeConfig(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else { throw OpenSSHExportError.invalidDestination }
        let previousPermissions = (
            try? files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )?.intValue
        try data.write(to: url, options: .atomic)
        try files.setAttributes(
            [.posixPermissions: previousPermissions ?? 0o600],
            ofItemAtPath: url.path
        )
    }
}
#endif
