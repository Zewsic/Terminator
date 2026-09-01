import AppKit
import Foundation
import TerminatorCore

#if !APP_STORE
actor MacTermiusImportService: ExternalImportService {
    private let files = FileManager.default
    private let databaseNames = [
        "hosts", "keys", "ssh_identities", "ssh_configs", "proxies", "groups",
        "tags", "tag_hosts", "pf_rules", "known_hosts",
    ]

    func availableSources() async -> [ExternalImportSource] {
        await MainActor.run {
            var result: [ExternalImportSource] = []
            if let url = applicationURL(bundleID: "com.termius-dmg.mac", fallback: "/Applications/Termius.app") {
                result.append(.init(kind: .termiusDirect, displayName: "Termius Direct", applicationURL: url))
            }
            if let url = applicationURL(bundleID: "com.termius.mac", fallback: nil),
               !result.contains(where: { $0.applicationURL?.standardizedFileURL == url.standardizedFileURL }) {
                result.append(.init(kind: .termiusAppStore, displayName: "Termius App Store", applicationURL: url))
            }
            return result
        }
    }

    func scan(_ source: ExternalImportSource) async throws -> ExternalImportBundle {
        guard let appURL = source.applicationURL else { throw TermiusImportError.applicationNotFound }
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        let isRunning = await MainActor.run {
            bundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
        }
        if isRunning {
            throw TermiusImportError.quitTermius(source.displayName)
        }

        let port = source.kind == .termiusAppStore ? 49_323 : 49_322
        let executable = appURL.appending(path: "Contents/MacOS/Termius")
        guard files.isExecutableFile(atPath: executable.path) else { throw TermiusImportError.invalidApplication }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--remote-debugging-port=\(port)", "--remote-debugging-address=127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let encrypted = try await exportIndexedDBWithRetry(port: port, appURL: appURL)
        let decrypted = try decrypt(encrypted, appURL: appURL, source: source)
        return try TermiusNormalizer(source: source, root: decrypted).bundle()
    }

    @MainActor
    private func applicationURL(bundleID: String, fallback: String?) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        guard let fallback else { return nil }
        let url = URL(fileURLWithPath: fallback, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path),
              Bundle(url: url)?.bundleIdentifier == bundleID else { return nil }
        return url
    }

    private func waitForTarget(port: Int, appURL: URL) async throws -> URL {
        let endpoint = URL(string: "http://127.0.0.1:\(port)/json/list")!
        let deadline = Date.now.addingTimeInterval(30)
        while Date.now < deadline {
            if let (data, response) = try? await URLSession.shared.data(from: endpoint),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let targets = try? JSONDecoder().decode([DevToolsTarget].self, from: data),
               let match = targets.first(where: { target in
                   target.type == "page" && target.url.contains("ui-process") && target.webSocketDebuggerUrl != nil
               }), let value = match.webSocketDebuggerUrl, let url = URL(string: value) {
                return url
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        throw TermiusImportError.debugEndpointUnavailable(appURL.lastPathComponent)
    }

    private func exportIndexedDBWithRetry(port: Int, appURL: URL) async throws -> Data {
        for attempt in 0..<3 {
            do {
                let target = try await waitForTarget(port: port, appURL: appURL)
                return try await exportIndexedDB(webSocketURL: target)
            } catch {
                if attempt == 2 { throw error }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw TermiusImportError.invalidDatabaseResponse
    }

    private func exportIndexedDB(webSocketURL: URL) async throws -> Data {
        let task = URLSession.shared.webSocketTask(with: webSocketURL)
        task.maximumMessageSize = 64 * 1_024 * 1_024
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        var databases: [[String: Any]] = []
        for (offset, databaseName) in databaseNames.enumerated() {
            let names = try String(data: JSONEncoder().encode([databaseName]), encoding: .utf8) ?? "[]"
            let expression = "(\(Self.browserExporter))(\(names))"
            let json = try await evaluate(expression, id: offset + 1, on: task)
            guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let values = object["databases"] as? [[String: Any]] else {
                throw TermiusImportError.invalidDatabaseResponse
            }
            databases.append(contentsOf: values)
        }
        return try JSONSerialization.data(withJSONObject: ["databases": databases])
    }

    private func evaluate(
        _ expression: String,
        id: Int,
        on task: URLSessionWebSocketTask
    ) async throws -> String {
        let request: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "awaitPromise": true, "returnByValue": true, "timeout": 60_000],
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let jsonRequest = String(data: data, encoding: .utf8) else {
            throw TermiusImportError.invalidDatabaseResponse
        }
        try await task.send(.string(jsonRequest))
        while true {
            let message = try await task.receive()
            let responseData: Data
            switch message {
            case .data(let data): responseData = data
            case .string(let string): responseData = Data(string.utf8)
            @unknown default: throw TermiusImportError.invalidDatabaseResponse
            }
            guard let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                throw TermiusImportError.invalidDatabaseResponse
            }
            guard (root["id"] as? Int) == id else { continue }
            if let details = root["error"] as? [String: Any] {
                throw TermiusImportError.databaseEvaluationFailed(String(describing: details["message"] ?? details))
            }
            guard let result = root["result"] as? [String: Any] else {
                throw TermiusImportError.invalidDatabaseResponse
            }
            if let details = result["exceptionDetails"] as? [String: Any] {
                let exception = details["exception"] as? [String: Any]
                throw TermiusImportError.databaseEvaluationFailed(
                    String(describing: exception?["description"] ?? details["text"] ?? details)
                )
            }
            guard let inner = result["result"] as? [String: Any],
                  let json = inner["value"] as? String else {
                throw TermiusImportError.invalidDatabaseResponse
            }
            return json
        }
    }

    private func decrypt(_ encrypted: Data, appURL: URL, source: ExternalImportSource) throws -> Any {
        let temporary = files.temporaryDirectory.appending(path: "Terminator-Termius-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let input = temporary.appending(path: "indexeddb.json")
        try encrypted.write(to: input, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)

        guard let script = Bundle.main.url(forResource: "TermiusDecrypt", withExtension: "js") else {
            throw TermiusImportError.missingDecryptor
        }
        let resources = appURL.appending(path: "Contents/Resources/app.asar.unpacked/node_modules")
        let executable = appURL.appending(path: "Contents/MacOS/Termius")
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            script.path, input.path,
            resources.appending(path: "@termius/keytar").path,
            resources.appending(path: "@termius/libtermius").path,
            source.kind == .termiusAppStore ? "Termius (MAS)" : "Termius",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TermiusImportError.decryptionFailed(message ?? "Unknown error")
        }
        return try JSONSerialization.jsonObject(with: output)
    }

    private struct DevToolsTarget: Decodable {
        var type: String
        var url: String
        var webSocketDebuggerUrl: String?
    }

    private static let browserExporter = #"async function(names) { const request = r => new Promise((ok, no) => { r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); }); const available = indexedDB.databases ? await indexedDB.databases() : []; const wanted = new Set(names); const databases = []; for (const info of available) { if (!info.name || !wanted.has(info.name)) continue; const db = await request(indexedDB.open(info.name)); const stores = {}; for (const storeName of Array.from(db.objectStoreNames)) { const tx = db.transaction(storeName, 'readonly'); const store = tx.objectStore(storeName); const keys = await request(store.getAllKeys()); const values = await request(store.getAll()); stores[storeName] = values.map((value, index) => ({ key: keys[index], value })); } databases.push({ name: db.name, stores }); db.close(); } return JSON.stringify({ databases }); }"#
}

private enum TermiusImportError: LocalizedError {
    case applicationNotFound, invalidApplication, invalidDatabaseResponse, missingDecryptor
    case quitTermius(String), debugEndpointUnavailable(String), decryptionFailed(String)
    case databaseEvaluationFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotFound: "Termius is no longer installed."
        case .invalidApplication: "The selected Termius application is incomplete."
        case .invalidDatabaseResponse: "Termius returned an unreadable IndexedDB response."
        case .missingDecryptor: "The bundled Termius import helper is missing."
        case .quitTermius(let name): "Quit \(name), then try loading it again."
        case .debugEndpointUnavailable(let name): "Could not open the local import endpoint for \(name)."
        case .decryptionFailed(let message): "Could not unlock Termius data: \(message)"
        case .databaseEvaluationFailed(let message): "Termius could not read its local database: \(message)"
        }
    }
}

private nonisolated struct TermiusNormalizer {
    let source: ExternalImportSource
    let tables: [String: [[String: Any]]]

    init(source: ExternalImportSource, root: Any) throws {
        self.source = source
        guard let object = root as? [String: Any], let databases = object["databases"] as? [[String: Any]] else {
            throw TermiusImportError.invalidDatabaseResponse
        }
        var result: [String: [[String: Any]]] = [:]
        for database in databases {
            guard let name = database["name"] as? String,
                  let stores = database["stores"] as? [String: Any],
                  let rows = stores.values.first as? [[String: Any]] else { continue }
            result[name] = rows.compactMap { $0["value"] as? [String: Any] }
        }
        tables = result
    }

    func bundle() throws -> ExternalImportBundle {
        let keys = table("keys").compactMap { row -> ExternalImportAccessKey? in
            let privateKey = text(row["private_key"])
            guard !privateKey.isEmpty else { return nil }
            return .init(id: entityID(row), label: text(row["label"]), privateKey: privateKey,
                         publicKey: text(row["public_key"]), passphrase: text(row["passphrase"]))
        }
        let keyIndex = index(table("keys"))
        let identityRows = table("ssh_identities")
        let identityIndex = index(identityRows)
        let configIndex = index(table("ssh_configs"))
        let groupIndex = index(table("groups"))
        let proxyRows = table("proxies")
        let proxyIndex = index(proxyRows)
        let hostRows = table("hosts")
        let hostIndex = index(hostRows)

        let identities = identityRows.map { row -> ExternalImportIdentity in
            let key = dereference(row["ssh_key"], in: keyIndex)
            return .init(id: entityID(row), label: text(row["label"]), username: text(row["username"]),
                         password: text(row["password"]), accessKeyIDs: key.map { [entityID($0)] } ?? [])
        }
        let proxies = proxyRows.compactMap { row -> ExternalImportProxy? in
            let hostname = text(row["hostname"])
            guard !hostname.isEmpty else { return nil }
            let identity = dereference(row["identity"], in: identityIndex)
            return .init(id: entityID(row), kind: text(row["type"]), hostname: hostname, port: integer(row["port"]),
                         username: text(identity?["username"]), password: text(identity?["password"]))
        }

        let tunnels = table("pf_rules").map { row -> ExternalImportTunnel in
            let owner = dereference(row["host"], in: hostIndex)
            let rawKind = text(row["pf_type"]).lowercased()
            let kind: ExternalImportTunnelKind = rawKind.hasPrefix("remote") ? .remote : (rawKind.hasPrefix("dynamic") ? .dynamic : .local)
            let bindAddress = text(row["bound_address"])
            return .init(id: entityID(row), hostID: owner.map(entityID), label: text(row["label"]), kind: kind,
                         bindAddress: bindAddress.isEmpty ? "127.0.0.1" : bindAddress, localPort: integer(row["local_port"]),
                         targetHost: text(row["hostname"]), targetPort: integer(row["remote_port"]))
        }

        var tagsByHost: [String: [String]] = [:]
        let tagIndex = index(table("tags"))
        for link in table("tag_hosts") {
            guard let host = dereference(link["host"], in: hostIndex), let tag = dereference(link["tag"], in: tagIndex) else { continue }
            let label = text(tag["label"])
            if !label.isEmpty { tagsByHost[entityID(host), default: []].append(label) }
        }
        let tunnelIDsByHost = Dictionary(grouping: tunnels.compactMap { tunnel in tunnel.hostID.map { ($0, tunnel.id) } }, by: \.0)
            .mapValues { $0.map(\.1) }

        let hosts = hostRows.compactMap { row -> ExternalImportHost? in
            let address = expandedIPv4(text(row["address"]))
            guard !address.isEmpty else { return nil }
            let config = dereference(row["ssh_config"], in: configIndex) ?? [:]
            let identity = dereference(config["identity"] ?? row["identity"], in: identityIndex)
            let key = dereference(identity?["ssh_key"], in: keyIndex)
            let group = dereference(row["group"], in: groupIndex)
            let proxy = dereference(config["proxycommand"], in: proxyIndex)
            let id = entityID(row)
            let label = text(row["label"])
            return .init(id: id, label: label.isEmpty ? address : label, hostname: address,
                         port: max(1, integer(config["port"], fallback: 22)), group: text(group?["label"]),
                         tags: Array(Set(tagsByHost[id] ?? [])).sorted(), identityID: identity.map(entityID),
                         accessKeyID: key.map(entityID), proxyID: proxy.map(entityID), tunnelIDs: tunnelIDsByHost[id] ?? [])
        }
        let knownHosts = table("known_hosts").compactMap { row -> ExternalImportKnownHost? in
            let hostnames = text(row["hostnames"]), key = text(row["key"])
            guard !hostnames.isEmpty, !key.isEmpty else { return nil }
            return .init(id: entityID(row), hostnames: hostnames, key: key, marker: text(row["marker"]), comment: text(row["comment"]))
        }
        return .init(source: source, hosts: hosts.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending },
                     identities: identities, accessKeys: keys, tunnels: tunnels, proxies: proxies, knownHosts: knownHosts)
    }

    private func table(_ name: String) -> [[String: Any]] { deduplicated(tables[name] ?? []) }
    private func deduplicated(_ rows: [[String: Any]]) -> [[String: Any]] {
        var latest: [String: [String: Any]] = [:]
        for row in rows {
            let key = entityID(row)
            if let previous = latest[key], text(previous["updated_at"]) > text(row["updated_at"]) { continue }
            latest[key] = row
        }
        return Array(latest.values)
    }
    private func index(_ rows: [[String: Any]]) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for row in rows {
            if let id = row["id"] { result["id:\(id)"] = row }
            if let id = row["local_id"] { result["local:\(id)"] = row }
        }
        return result
    }
    private func dereference(_ reference: Any?, in index: [String: [String: Any]]) -> [String: Any]? {
        guard let reference else { return nil }
        if let row = reference as? [String: Any] {
            if let id = row["id"], let found = index["id:\(id)"] { return found }
            if let id = row["local_id"], let found = index["local:\(id)"] { return found }
            return row
        }
        return index["id:\(reference)"] ?? index["local:\(reference)"]
    }
    private func entityID(_ row: [String: Any]) -> String {
        if let id = row["id"] { return "id:\(id)" }
        if let id = row["local_id"] { return "local:\(id)" }
        return "anonymous:\(abs(String(describing: row).hashValue))"
    }
    private func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return (value as? String ?? String(describing: value)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func integer(_ value: Any?, fallback: Int = 0) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return Int(text(value)) ?? fallback
    }
    private func expandedIPv4(_ value: String) -> String {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let packed = UInt32(value) else { return value }
        return "\(packed >> 24).\((packed >> 16) & 255).\((packed >> 8) & 255).\(packed & 255)"
    }
}

#endif
