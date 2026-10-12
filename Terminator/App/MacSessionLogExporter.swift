#if !APP_STORE
import AppKit
import Foundation
import TerminatorCore
import TerminatorFeatures
import TerminatorSSH
actor MacSessionLogExporter: SessionLogExporting {
    private let secretStore: any SecretStore
    private let baseURL: URL

    init(secretStore: any SecretStore, baseURL: URL) {
        self.secretStore = secretStore; self.baseURL = baseURL
    }

    func export(_ log: SessionLogMetadata) async throws -> URL? {
        let destination = await MainActor.run { () -> URL? in
            NSApp.activate(ignoringOtherApps: true)
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = AppL10n.text(.exportWarningTitle)
            warning.informativeText = AppL10n.text(.exportWarningMessage)
            warning.addButton(withTitle: AppL10n.text(.actionContinue))
            warning.addButton(withTitle: AppL10n.text(.actionCancel))
            guard warning.runModal() == .alertFirstButtonReturn else { return nil }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(log.hostDisplayName)-\(log.startedAt.formatted(.iso8601)).terminator-session"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
        guard let destination else { return nil }
        let chunks = try await SessionLogWriter.readChunks(metadata: log, secretStore: secretStore, baseURL: baseURL)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var transcript = Data()
        for chunk in chunks where chunk.kind == .stdout || chunk.kind == .stderr { transcript.append(chunk.payload) }
        try transcript.write(to: destination.appending(path: "transcript.ansi"), options: .atomic)
        try JSONEncoder().encode(chunks).write(to: destination.appending(path: "events.json"), options: .atomic)
        let redacted = ExportMetadata(host: log.hostDisplayName, terminal: log.terminal.displayName, startedAt: log.startedAt, endedAt: log.endedAt, reconnectCount: log.reconnectCount, incomplete: log.state == .incomplete)
        try JSONEncoder().encode(redacted).write(to: destination.appending(path: "metadata.json"), options: .atomic)
        return destination
    }

    func transcript(_ log: SessionLogMetadata) async throws -> String {
        let chunks = try await SessionLogWriter.readChunks(metadata: log, secretStore: secretStore, baseURL: baseURL)
        let raw = chunks
            .filter { $0.kind == .stdout || $0.kind == .stderr || $0.kind == .status }
            .map { String(decoding: $0.payload, as: UTF8.self) }
            .joined()
        return Self.stripANSI(raw)
    }

    private static func stripANSI(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{1b}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "[" {
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex, !("@-~".contains(text[cursor])) {
                        cursor = text.index(after: cursor)
                    }
                    if cursor < text.endIndex { cursor = text.index(after: cursor) }
                    index = cursor
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private struct ExportMetadata: Codable {
        var host: String; var terminal: String; var startedAt: Date; var endedAt: Date?
        var reconnectCount: Int; var incomplete: Bool
    }
}

#endif
