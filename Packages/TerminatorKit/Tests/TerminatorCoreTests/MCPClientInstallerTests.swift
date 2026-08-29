import Foundation
import Testing
@testable import TerminatorCore

@Suite("MCP client installer")
struct MCPClientInstallerTests {
    @Test("Installs and removes a Grok TOML server without touching other tables")
    func grokTOMLRoundTrip() throws {
        let home = try scratchHome()
        let grok = home.appending(path: ".grok")
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        let config = grok.appending(path: "config.toml")
        try Data("""
        [cli]
        installer = "internal"

        [mcp_servers.terminator]
        command = "/old/terminator-service"
        args = ["mcp"]
        enabled = true
        startup_timeout_sec = 30
        """.utf8).write(to: config)

        MCPClientInstaller.sync(
            enabled: true,
            commandPath: "/Applications/Terminator.app/Contents/Helpers/terminator-service",
            home: home,
            applicationDirectories: []
        )

        var text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.contains("[cli]"))
        #expect(text.contains("installer = \"internal\""))
        #expect(text.contains("[mcp_servers.terminator]"))
        #expect(text.contains("command = \"/Applications/Terminator.app/Contents/Helpers/terminator-service\""))
        #expect(text.contains("args = [\"mcp\"]"))
        #expect(text.contains("enabled = true"))
        #expect(text.contains("startup_timeout_sec = 30"))

        MCPClientInstaller.sync(enabled: false, commandPath: "/unused", home: home, applicationDirectories: [])
        text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.contains("[cli]"))
        #expect(!text.contains("mcp_servers.terminator"))
        #expect(!text.contains("terminator-service"))
    }

    @Test("Creates Cursor mcp.json when the app bundle is present")
    func createsCursorConfigFromApp() throws {
        let home = try scratchHome()
        let apps = home.appending(path: "Apps")
        try FileManager.default.createDirectory(
            at: apps.appending(path: "Cursor.app"), withIntermediateDirectories: true
        )

        MCPClientInstaller.sync(
            enabled: true,
            commandPath: "/opt/terminator-service",
            home: home,
            applicationDirectories: [apps]
        )

        let config = home.appending(path: ".cursor/mcp.json")
        let object = try json(config)
        let server = try #require(object["mcpServers"] as? [String: Any]).terminator
        #expect(server["command"] as? String == "/opt/terminator-service")
        #expect(server["args"] as? [String] == ["mcp"])

        MCPClientInstaller.sync(enabled: false, commandPath: "/opt/terminator-service", home: home, applicationDirectories: [apps])
        let after = try json(config)
        let servers = try #require(after["mcpServers"] as? [String: Any])
        #expect(servers["terminator"] == nil)
    }

    @Test("Merges into existing Claude Code JSON")
    func mergesClaudeJSON() throws {
        let home = try scratchHome()
        let config = home.appending(path: ".claude.json")
        try Data(#"""
        {"theme":"dark","mcpServers":{"github":{"command":"npx"}}}
        """#.utf8).write(to: config)

        MCPClientInstaller.sync(
            enabled: true,
            commandPath: "/bin/terminator-service",
            home: home,
            applicationDirectories: []
        )

        let object = try json(config)
        #expect(object["theme"] as? String == "dark")
        let servers = try #require(object["mcpServers"] as? [String: Any])
        #expect(servers["github"] != nil)
        #expect(servers.terminator["command"] as? String == "/bin/terminator-service")
    }

    @Test("Writes VS Code stdio type and skips clients that are not installed")
    func vscodeAndUnknown() throws {
        let home = try scratchHome()
        try FileManager.default.createDirectory(
            at: home.appending(path: "Library/Application Support/Code/User"),
            withIntermediateDirectories: true
        )

        MCPClientInstaller.sync(
            enabled: true,
            commandPath: "/usr/bin/terminator-service",
            home: home,
            applicationDirectories: []
        )

        let vscode = try json(home.appending(path: "Library/Application Support/Code/User/mcp.json"))
        let server = try #require(vscode["servers"] as? [String: Any]).terminator
        #expect(server["type"] as? String == "stdio")
        #expect(server["command"] as? String == "/usr/bin/terminator-service")

        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".gemini/settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".codex/config.toml").path))
    }

    @Test("Leaves invalid JSON files untouched")
    func skipsInvalidJSON() throws {
        let home = try scratchHome()
        try FileManager.default.createDirectory(at: home.appending(path: ".cursor"), withIntermediateDirectories: true)
        let config = home.appending(path: ".cursor/mcp.json")
        let original = Data("not-json".utf8)
        try original.write(to: config)

        MCPClientInstaller.sync(
            enabled: true,
            commandPath: "/bin/terminator-service",
            home: home,
            applicationDirectories: []
        )

        #expect(try Data(contentsOf: config) == original)
    }

    @Test("Registers Zed context_servers")
    func zedContextServers() throws {
        let home = try scratchHome()
        try FileManager.default.createDirectory(at: home.appending(path: ".config/zed"), withIntermediateDirectories: true)
        let config = home.appending(path: ".config/zed/settings.json")
        try Data(#"{"theme":"zed"}"#.utf8).write(to: config)

        MCPClientInstaller.sync(
            enabled: true,
            commandPath: "/bin/terminator-service",
            home: home,
            applicationDirectories: []
        )

        let object = try json(config)
        #expect(object["theme"] as? String == "zed")
        let servers = try #require(object["context_servers"] as? [String: Any]).terminator
        #expect(servers["source"] as? String == "custom")
        #expect(servers["command"] as? String == "/bin/terminator-service")
    }

    private func scratchHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "terminator-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private extension [String: Any] {
    var terminator: [String: Any] {
        self[MCPClientInstaller.serverName] as? [String: Any] ?? [:]
    }
}
