import Foundation

public enum MCPClientInstaller: Sendable {
    public static let serverName = "terminator"
    public static let defaultArgs = ["mcp"]

    public static func sync(
        enabled: Bool,
        commandPath: String,
        args: [String] = defaultArgs,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil
    ) {
        let applications = applicationDirectories ?? defaultApplicationDirectories(home: home)
        for client in catalog {
            let url = home.appending(path: client.configPath)
            if enabled {
                guard isPresent(client, home: home, config: url, applicationDirectories: applications) else { continue }
                try? upsert(client, url: url, commandPath: commandPath, args: args)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try? remove(client, url: url)
            }
        }
    }

    public static func defaultApplicationDirectories(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    static let catalog: [Client] = [
        Client(
            id: "grok",
            configPath: ".grok/config.toml",
            format: .tomlTable("mcp_servers.terminator"),
            markers: [".grok"],
            appBundles: []
        ),
        Client(
            id: "claude-desktop",
            configPath: "Library/Application Support/Claude/claude_desktop_config.json",
            format: .jsonMap("mcpServers"),
            markers: ["Library/Application Support/Claude"],
            appBundles: ["Claude.app"]
        ),
        Client(
            id: "claude-code",
            configPath: ".claude.json",
            format: .jsonMap("mcpServers"),
            markers: [".claude", ".claude.json"],
            appBundles: []
        ),
        Client(
            id: "cursor",
            configPath: ".cursor/mcp.json",
            format: .jsonMap("mcpServers"),
            markers: [".cursor"],
            appBundles: ["Cursor.app"]
        ),
        Client(
            id: "vscode",
            configPath: "Library/Application Support/Code/User/mcp.json",
            format: .jsonMap("servers", extras: ["type": "stdio"]),
            markers: ["Library/Application Support/Code"],
            appBundles: ["Visual Studio Code.app"]
        ),
        Client(
            id: "vscode-insiders",
            configPath: "Library/Application Support/Code - Insiders/User/mcp.json",
            format: .jsonMap("servers", extras: ["type": "stdio"]),
            markers: ["Library/Application Support/Code - Insiders"],
            appBundles: ["Visual Studio Code - Insiders.app"]
        ),
        Client(
            id: "vscodium",
            configPath: "Library/Application Support/VSCodium/User/mcp.json",
            format: .jsonMap("servers", extras: ["type": "stdio"]),
            markers: ["Library/Application Support/VSCodium"],
            appBundles: ["VSCodium.app"]
        ),
        Client(
            id: "windsurf",
            configPath: ".codeium/windsurf/mcp_config.json",
            format: .jsonMap("mcpServers"),
            markers: [".codeium/windsurf"],
            appBundles: ["Windsurf.app"]
        ),
        Client(
            id: "codex",
            configPath: ".codex/config.toml",
            format: .tomlTable("mcp_servers.terminator"),
            markers: [".codex"],
            appBundles: []
        ),
        Client(
            id: "gemini",
            configPath: ".gemini/settings.json",
            format: .jsonMap("mcpServers"),
            markers: [".gemini"],
            appBundles: []
        ),
        Client(
            id: "zed",
            configPath: ".config/zed/settings.json",
            format: .zedContextServers,
            markers: [".config/zed"],
            appBundles: ["Zed.app"]
        ),
    ]

    struct Client: Equatable, Sendable {
        var id: String
        var configPath: String
        var format: Format
        var markers: [String]
        var appBundles: [String]
    }

    enum Format: Equatable, Sendable {
        case jsonMap(String, extras: [String: String] = [:])
        case zedContextServers
        case tomlTable(String)
    }

    private static func isPresent(
        _ client: Client,
        home: URL,
        config: URL,
        applicationDirectories: [URL]
    ) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: config.path) { return true }
        for marker in client.markers {
            if fm.fileExists(atPath: home.appending(path: marker).path) { return true }
        }
        for directory in applicationDirectories {
            for bundle in client.appBundles {
                if fm.fileExists(atPath: directory.appending(path: bundle).path) { return true }
            }
        }
        return false
    }

    private static func upsert(_ client: Client, url: URL, commandPath: String, args: [String]) throws {
        switch client.format {
        case .jsonMap(let key, let extras):
            try mutateJSON(url: url, mapKey: key, extras: extras, commandPath: commandPath, args: args, removing: false)
        case .zedContextServers:
            try mutateZed(url: url, commandPath: commandPath, args: args, removing: false)
        case .tomlTable(let header):
            try mutateTOML(url: url, header: header, commandPath: commandPath, args: args, removing: false)
        }
    }

    private static func remove(_ client: Client, url: URL) throws {
        switch client.format {
        case .jsonMap(let key, _):
            try mutateJSON(url: url, mapKey: key, extras: [:], commandPath: "", args: [], removing: true)
        case .zedContextServers:
            try mutateZed(url: url, commandPath: "", args: [], removing: true)
        case .tomlTable(let header):
            try mutateTOML(url: url, header: header, commandPath: "", args: [], removing: true)
        }
    }

    private static func mutateJSON(
        url: URL,
        mapKey: String,
        extras: [String: String],
        commandPath: String,
        args: [String],
        removing: Bool
    ) throws {
        guard var root = try loadJSONObject(url: url, creating: !removing) else { return }
        var map = root[mapKey] as? [String: Any] ?? [:]
        if removing {
            map.removeValue(forKey: serverName)
        } else {
            var entry: [String: Any] = ["command": commandPath, "args": args]
            for (key, value) in extras { entry[key] = value }
            map[serverName] = entry
        }
        root[mapKey] = map
        try writeJSON(root, to: url)
    }

    private static func mutateZed(url: URL, commandPath: String, args: [String], removing: Bool) throws {
        guard var root = try loadJSONObject(url: url, creating: !removing) else { return }
        var servers = root["context_servers"] as? [String: Any] ?? [:]
        if removing {
            servers.removeValue(forKey: serverName)
        } else {
            servers[serverName] = [
                "source": "custom",
                "command": commandPath,
                "args": args,
            ] as [String: Any]
        }
        root["context_servers"] = servers
        try writeJSON(root, to: url)
    }

    private static func mutateTOML(
        url: URL,
        header: String,
        commandPath: String,
        args: [String],
        removing: Bool
    ) throws {
        let existing = FileManager.default.fileExists(atPath: url.path)
        if removing && !existing { return }
        var text = existing ? try String(contentsOf: url, encoding: .utf8) : ""
        if removing {
            text = removeTOMLTable(text, header: header)
        } else {
            text = upsertTOMLTable(text, header: header, values: [
                ("command", tomlQuote(commandPath)),
                ("args", tomlArray(args)),
                ("enabled", "true"),
            ])
        }
        try writeText(text, to: url)
    }

    private static func loadJSONObject(url: URL, creating: Bool) throws -> [String: Any]? {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return creating ? [:] : nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return creating ? [:] : nil
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try writeData(data, to: url)
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try writeData(Data(text.utf8), to: url)
    }

    private static func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private func upsertTOMLTable(_ text: String, header: String, values: [(String, String)]) -> String {
    var lines = tomlLines(text)
    let headerLine = "[\(header)]"
    if let start = lines.firstIndex(where: { isTOMLHeader($0, header) }) {
        var end = start + 1
        while end < lines.count && !isTOMLTableHeader(lines[end]) { end += 1 }
        var body = Array(lines[(start + 1)..<end])
        for (key, value) in values {
            if let index = body.firstIndex(where: { tomlKey($0) == key }) {
                body[index] = "\(key) = \(value)"
            } else {
                var insertAt = body.endIndex
                while insertAt > 0, body[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    insertAt -= 1
                }
                body.insert("\(key) = \(value)", at: insertAt)
            }
        }
        lines.replaceSubrange(start..<end, with: [headerLine] + body)
        return joinTOML(lines, originallyEndedWithNewline: text.hasSuffix("\n") || text.isEmpty)
    }
    var result = text
    if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
    if !result.isEmpty { result += "\n" }
    result += headerLine + "\n"
    for (key, value) in values {
        result += "\(key) = \(value)\n"
    }
    return result
}

private func removeTOMLTable(_ text: String, header: String) -> String {
    var lines = tomlLines(text)
    guard let start = lines.firstIndex(where: { isTOMLHeader($0, header) }) else { return text }
    var end = start + 1
    while end < lines.count && !isTOMLTableHeader(lines[end]) { end += 1 }
    lines.removeSubrange(start..<end)
    while start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
        lines.remove(at: start)
        break
    }
    return joinTOML(lines, originallyEndedWithNewline: text.hasSuffix("\n"))
}

private func tomlLines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map {
        $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
    }
}

private func joinTOML(_ lines: [String], originallyEndedWithNewline: Bool) -> String {
    var joined = lines.joined(separator: "\n")
    if originallyEndedWithNewline, !joined.hasSuffix("\n"), !joined.isEmpty { joined += "\n" }
    while joined.contains("\n\n\n") { joined = joined.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
    return joined
}

private func isTOMLTableHeader(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
}

private func isTOMLHeader(_ line: String, _ header: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("#") { return false }
    return trimmed == "[\(header)]" || trimmed == "[mcp_servers.\"terminator\"]"
}

private func tomlKey(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !isTOMLTableHeader(trimmed) else { return nil }
    guard let equals = trimmed.firstIndex(of: "=") else { return nil }
    return trimmed[..<equals].trimmingCharacters(in: .whitespaces)
}

private func tomlQuote(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
}

private func tomlArray(_ values: [String]) -> String {
    "[\(values.map(tomlQuote).joined(separator: ", "))]"
}
