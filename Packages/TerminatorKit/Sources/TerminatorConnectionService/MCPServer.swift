#if os(macOS)
import Foundation
import TerminatorCore
import TerminatorSSH

enum TerminatorMCPServer {
    static func run() {
        guard AccessPreferencesStore.load().mcpEnabled else {
            FileHandle.standardError.write(Data("terminator-service: MCP access is turned off in Settings.\n".utf8))
            Foundation.exit(1)
        }
        let client = ConnectionServiceClient()
        Task {
            do {
                try await serve(client: client)
                Foundation.exit(0)
            } catch {
                FileHandle.standardError.write(Data("terminator-service: \(error.localizedDescription)\n".utf8))
                Foundation.exit(1)
            }
        }
        RunLoop.main.run()
    }

    private static func serve(client: ConnectionServiceClient) async throws {
        let stdin = FileHandle.standardInput
        var buffer = Data()
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let message = popMessage(&buffer) {
                if let reply = await handle(message, client: client) {
                    writeMessage(reply)
                }
            }
        }
    }

    private static func handle(_ data: Data, client: ConnectionServiceClient) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let method = object["method"] as? String ?? ""
        let id = object["id"]
        if method == "notifications/initialized" || method.hasPrefix("notifications/") { return nil }
        switch method {
        case "initialize":
            return rpcOK(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "terminator", "version": "0.1.0"],
            ])
        case "ping":
            return rpcOK(id: id, result: [:])
        case "tools/list":
            return rpcOK(id: id, result: ["tools": toolList()])
        case "tools/call":
            let params = object["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, arguments: arguments, client: client)
                return rpcOK(id: id, result: [
                    "content": [["type": "text", "text": text]],
                ])
            } catch {
                return rpcOK(id: id, result: [
                    "content": [["type": "text", "text": error.localizedDescription]],
                    "isError": true,
                ])
            }
        default:
            return rpcError(id: id, message: "Method not found: \(method)")
        }
    }

    private static func call(
        _ name: String,
        arguments: [String: Any],
        client: ConnectionServiceClient
    ) async throws -> String {
        switch name {
        case "list_hosts":
            let hosts = try await client.listHosts()
            return encodeJSON(hosts.map {
                [
                    "id": $0.id.uuidString,
                    "name": $0.name,
                    "hostname": $0.hostname,
                    "port": $0.port,
                    "phase": String(describing: $0.phase),
                ] as [String: Any]
            })
        case "connect":
            let hostID = try await resolveHost(arguments["host"], client: client)
            if bool(arguments["open_terminal"], default: false) {
                try await client.connect(hostID: hostID, terminal: .terminal)
                return "Connected \(hostID.uuidString) and opened Terminal."
            }
            let sessionID = try await client.connectHeadless(hostID: hostID)
            return encodeJSON(["host_id": hostID.uuidString, "session_id": sessionID.uuidString])
        case "disconnect":
            let hostID = try await resolveHost(arguments["host"], client: client)
            await client.disconnect(hostID: hostID)
            return "Disconnected \(hostID.uuidString)."
        case "list_sessions":
            let sessions = try await client.listSessions()
            return encodeJSON(sessions.map {
                [
                    "id": $0.id.uuidString,
                    "host_id": $0.hostID.uuidString,
                    "host": $0.hostName,
                    "kind": $0.kind,
                ] as [String: Any]
            })
        case "send":
            guard let session = uuid(arguments["session_id"]) else {
                throw ConnectionServiceError.failed("session_id is required.")
            }
            var text = arguments["text"] as? String ?? ""
            if bool(arguments["submit"], default: true), !text.hasSuffix("\n") { text += "\n" }
            try await client.writeSession(id: session, text: text)
            return "Sent."
        case "read_output":
            guard let session = uuid(arguments["session_id"]) else {
                throw ConnectionServiceError.failed("session_id is required.")
            }
            let after = (arguments["after"] as? Int) ?? 0
            let snapshot = try await client.readSession(id: session, after: after)
            return encodeJSON(["text": snapshot.text, "next": snapshot.next])
        default:
            throw ConnectionServiceError.failed("Unknown tool: \(name)")
        }
    }

    private static func resolveHost(_ value: Any?, client: ConnectionServiceClient) async throws -> UUID {
        let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { throw ConnectionServiceError.failed("host is required.") }
        if let id = UUID(uuidString: raw) { return id }
        let hosts = try await client.listHosts()
        let matches = hosts.filter {
            $0.name.caseInsensitiveCompare(raw) == .orderedSame
                || $0.hostname.caseInsensitiveCompare(raw) == .orderedSame
        }
        guard let host = matches.first, matches.count == 1 else {
            throw ConnectionServiceError.failed("Host not found: \(raw)")
        }
        return host.id
    }

    private static func toolList() -> [[String: Any]] { [
        tool("list_hosts", "List saved SSH hosts and connection state."),
        tool(
            "connect",
            "Connect to a host. Creates a headless shell and does not run the host start command, unless open_terminal is true.",
            [
                "host": ["type": "string", "description": "Host id, name, or hostname"],
                "open_terminal": ["type": "boolean", "description": "Open Terminal.app instead of a headless session"],
            ],
            required: ["host"]
        ),
        tool(
            "disconnect",
            "Disconnect a host.",
            ["host": ["type": "string", "description": "Host id, name, or hostname"]],
            required: ["host"]
        ),
        tool("list_sessions", "List live SSH sessions, including headless MCP sessions."),
        tool(
            "send",
            "Write to a session. Adds a newline unless submit is false.",
            [
                "session_id": ["type": "string"],
                "text": ["type": "string"],
                "submit": ["type": "boolean"],
            ],
            required: ["session_id", "text"]
        ),
        tool(
            "read_output",
            "Read new output from a headless session.",
            [
                "session_id": ["type": "string"],
                "after": ["type": "integer", "description": "Cursor from the previous read"],
            ],
            required: ["session_id"]
        ),
    ] }

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any] = [:],
        required: [String] = []
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ],
        ]
    }

    private static func popMessage(_ buffer: inout Data) -> Data? {
        let headerSeparator = Data("\r\n\r\n".utf8)
        if let range = buffer.range(of: headerSeparator),
           let header = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound), encoding: .utf8),
           let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
           let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) {
            let start = range.upperBound
            let end = buffer.index(start, offsetBy: length, limitedBy: buffer.endIndex)
            guard let end, buffer.distance(from: start, to: end) == length else { return nil }
            let body = buffer.subdata(in: start..<end)
            buffer.removeSubrange(..<end)
            return body
        }
        if let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(...newline)
            let trimmed = line.filter { $0 != 0x0D }
            return trimmed.isEmpty ? popMessage(&buffer) : Data(trimmed)
        }
        return nil
    }

    private static func writeMessage(_ body: Data) {
        // MCP stdio is newline-delimited JSON. Content-Length framing leaves Grok/rmcp
        // blocked on read_until('\n') because the JSON body has no trailing newline.
        var payload = body
        if payload.last != 0x0A { payload.append(0x0A) }
        FileHandle.standardOutput.write(payload)
    }

    private static func rpcOK(id: Any?, result: [String: Any]) -> Data {
        encodeJSONData(["jsonrpc": "2.0", "id": id as Any, "result": result])
    }

    private static func rpcError(id: Any?, message: String) -> Data {
        encodeJSONData(["jsonrpc": "2.0", "id": id as Any, "error": ["code": -32601, "message": message]])
    }

    private static func encodeJSON(_ value: Any) -> String {
        String(data: encodeJSONData(value), encoding: .utf8) ?? "{}"
    }

    private static func encodeJSONData(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func uuid(_ value: Any?) -> UUID? {
        UUID(uuidString: value as? String ?? "")
    }

    private static func bool(_ value: Any?, default fallback: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? String { return value == "true" || value == "1" }
        return fallback
    }
}
#endif
