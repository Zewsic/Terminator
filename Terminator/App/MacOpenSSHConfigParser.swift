#if !APP_STORE
import CryptoKit
import Foundation
import TerminatorCore

extension MacOpenSSHIntegrationService {
    struct ConfigBlock {
        var patterns: [String]
        var directives: [(key: String, value: String)]
    }

    func parseConfig(
        at url: URL, visited: inout Set<URL>, diagnostics: inout OpenSSHScanDiagnostics
    ) -> [ConfigBlock] {
        let canonical = url.standardizedFileURL
        guard visited.insert(canonical).inserted else {
            diagnostics.messages.append(AppL10n.text(.opensshImportRecursiveInclude, url.path))
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

    func tokenize(_ line: String) -> [String] {
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

    func isConcreteAlias(_ value: String) -> Bool {
        !value.hasPrefix("!") && !value.contains("*") && !value.contains("?")
    }

    func matches(_ value: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(escaped)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    func matches(_ value: String, patterns: [String]) -> Bool {
        if patterns.contains(where: { $0.hasPrefix("!") && matches(value, pattern: String($0.dropFirst())) }) {
            return false
        }
        return patterns.contains { !$0.hasPrefix("!") && matches(value, pattern: $0) }
    }

    func expandPath(_ path: String, relativeTo source: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return source.deletingLastPathComponent().appending(path: expanded).standardizedFileURL
    }

    func expandGlob(_ pattern: String, relativeTo source: URL) -> [URL] {
        let url = expandPath(pattern, relativeTo: source)
        guard pattern.contains("*") || pattern.contains("?") else { return [url] }
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        return ((try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { matches($0.lastPathComponent, pattern: name) }
            .sorted { $0.path < $1.path }
    }

    func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

}
#endif
