#if !APP_STORE
import AppKit
import Foundation
import TerminatorCore
import TerminatorFeatures
import TerminatorSSH

@MainActor
final class MacConnectionPrompter: SSHConnectionPrompting, @unchecked Sendable {
    let center: ConnectionPromptCenter

    init(center: ConnectionPromptCenter) { self.center = center }

    func requestPassphrase(for credential: CredentialMetadata) async throws -> String {
        NSApp.activate(ignoringOtherApps: true)
        return try await center.requestPassphrase(for: credential)
    }

    func trustNewHost(_ key: KnownHostKey) async throws -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return try await center.trustNewHost(key)
    }

    func confirmChangedHost(previous: KnownHostKey, presented: KnownHostKey) async throws -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return try await center.confirmChangedHost(previous: previous, presented: presented)
    }

    func requiresUserAttention(reason: String) async {
        NSApp.activate(ignoringOtherApps: true)
    }
}

actor MacExternalTerminalService: ExternalTerminalConnecting {
    private let coordinator: any SSHConnectionCoordinating
    private let broker: TerminalAttachBroker
    private let prompting: MacConnectionPrompter

    init(coordinator: any SSHConnectionCoordinating, broker: TerminalAttachBroker, prompting: MacConnectionPrompter) {
        self.coordinator = coordinator
        self.broker = broker
        self.prompting = prompting
    }

    func installedApplications() async -> [TerminalApplication] {
        await MainActor.run {
            TerminalApplication.allCases.filter { terminal in
                terminal == .other || applicationURL(for: terminal) != nil
            }
        }
    }

    func connect(host: HostProfile, terminal: TerminalApplication) async throws {
        try await coordinator.prepare(host: host, prompting: prompting)
        let descriptor = try await broker.createDescriptor(host: host, terminal: terminal)
        let helper = try await MainActor.run { try helperURL() }
        let command = await broker.command(for: descriptor, helperURL: helper)
        try await MainActor.run { try launch(terminal: terminal, command: command, descriptor: descriptor) }
    }
}

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
            warning.messageText = "Export decrypted terminal output?"
            warning.informativeText = "The exported package contains plaintext remote output, including ANSI escape sequences. Review it before sharing."
            warning.addButton(withTitle: "Continue")
            warning.addButton(withTitle: "Cancel")
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

    private struct ExportMetadata: Codable {
        var host: String; var terminal: String; var startedAt: Date; var endedAt: Date?
        var reconnectCount: Int; var incomplete: Bool
    }
}

@MainActor
private func helperURL() throws -> URL {
    if let bundled = Bundle.main.url(forAuxiliaryExecutable: "terminator-attach") { return bundled }
    let embedded = Bundle.main.bundleURL.appending(path: "Contents/Helpers/terminator-attach")
    if FileManager.default.isExecutableFile(atPath: embedded.path) { return embedded }
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        sourceRoot.appending(path: "Packages/TerminatorKit/.build/debug/terminator-attach"),
        sourceRoot.appending(path: "Packages/TerminatorKit/.build/arm64-apple-macosx/debug/terminator-attach")
    ]
    if let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return result }
    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "terminator-attach is not embedded in this build."])
}

@MainActor
private func launch(terminal: TerminalApplication, command: String, descriptor: AttachDescriptor) throws {
    switch terminal {
    case .other:
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    case .terminal:
        try launchCommandFile(command, applicationBundleID: "com.apple.Terminal")
    case .iTerm2:
        try runAppleScript("tell application \"iTerm\" to create window with default profile command \(appleScriptString(command))")
    case .ghostty:
        try launchCommandFile(command, applicationBundleID: "com.mitchellh.ghostty")
    case .wezTerm:
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.wez.wezterm") else { throw LaunchError.notInstalled }
        let executable = app.appending(path: "Contents/MacOS/wezterm")
        let process = Process(); process.executableURL = executable
        process.arguments = ["start", "--", "/bin/zsh", "-lc", command]
        try process.run()
    case .warp:
        try launchWarp(command: command, descriptor: descriptor)
    }
}

@MainActor
private func launchWarp(command: String, descriptor: AttachDescriptor) throws {
    guard applicationURL(for: .warp) != nil else { throw LaunchError.notInstalled }
    let name = "Terminator-\(descriptor.sessionID.uuidString)"
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".warp/launch_configurations", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let file = directory.appending(path: "\(name).yaml")
    let encodedCommand = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
    let configuration = """
    ---
    name: \(name)
    windows:
      - tabs:
          - title: Terminator
            layout:
              cwd: /tmp
              commands:
                - exec: \(encodedCommand)
    """
    try configuration.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    guard let url = URL(string: "warp://launch/\(name)") else {
        try? FileManager.default.removeItem(at: file)
        throw LaunchError.invalidURL
    }
    guard NSWorkspace.shared.open(url) else {
        try? FileManager.default.removeItem(at: file)
        throw LaunchError.openFailed
    }
    Task {
        try? await Task.sleep(for: .seconds(5))
        try? FileManager.default.removeItem(at: file)
    }
}

@MainActor
private func launchCommandFile(_ command: String, applicationBundleID: String) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TerminatorAttach-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = directory.appending(path: "Connect.command")
    let script = "#!/bin/zsh\n\(command)\nstatus=$?\nrm -rf -- \(shellQuote(directory.path))\nexit $status\n"
    try script.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: applicationBundleID) else { throw LaunchError.notInstalled }
    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
}

@MainActor private func runAppleScript(_ source: String) throws {
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { throw LaunchError.appleScript(error.description) }
}

private func bundleIdentifier(for terminal: TerminalApplication) -> String? {
    switch terminal {
    case .terminal: "com.apple.Terminal"
    case .iTerm2: "com.googlecode.iterm2"
    case .warp: "dev.warp.Warp-Stable"
    case .ghostty: "com.mitchellh.ghostty"
    case .wezTerm: "com.github.wez.wezterm"
    case .other: nil
    }
}

@MainActor
private func applicationURL(for terminal: TerminalApplication) -> URL? {
    if terminal == .warp {
        return ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp"]
            .lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }
    return bundleIdentifier(for: terminal).flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
}

private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
private func appleScriptString(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

private enum LaunchError: LocalizedError {
    case notInstalled, invalidURL, openFailed, appleScript(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: "Terminal application is not installed."
        case .invalidURL: "Unable to create terminal launch URL."
        case .openFailed: "The terminal application rejected the launch request."
        case .appleScript(let value): value
        }
    }
}
#endif
