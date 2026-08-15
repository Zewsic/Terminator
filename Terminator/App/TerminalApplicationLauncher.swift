#if !APP_STORE
import AppKit
import Foundation
import TerminatorCore
import TerminatorFeatures
func helperURL() throws -> URL {
    if let bundled = Bundle.main.url(forAuxiliaryExecutable: "terminator-attach") { return bundled }
    let embedded = Bundle.main.bundleURL.appending(path: "Contents/Helpers/terminator-attach")
    if FileManager.default.isExecutableFile(atPath: embedded.path) { return embedded }
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        sourceRoot.appending(path: "Packages/TerminatorKit/.build/debug/terminator-attach"),
        sourceRoot.appending(path: "Packages/TerminatorKit/.build/arm64-apple-macosx/debug/terminator-attach")
    ]
    if let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return result }
    throw CocoaError(
        .fileNoSuchFile,
        userInfo: [NSLocalizedDescriptionKey: AppL10n.text(.errorAttachNotEmbedded)]
    )
}

@MainActor
func launch(terminal: TerminalApplication, command: String, descriptor: AttachDescriptor) throws {
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
func launchWarp(command: String, descriptor: AttachDescriptor) throws {
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
func launchCommandFile(_ command: String, applicationBundleID: String) throws {
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

func bundleIdentifier(for terminal: TerminalApplication) -> String? {
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
func applicationURL(for terminal: TerminalApplication) -> URL? {
    if terminal == .warp {
        return ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp"]
            .lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }
    return bundleIdentifier(for: terminal).flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleScriptString(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

enum LaunchError: LocalizedError {
    case notInstalled, invalidURL, openFailed, appleScript(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: AppL10n.text(.errorTerminalNotInstalled)
        case .invalidURL: AppL10n.text(.errorTerminalInvalidURL)
        case .openFailed: AppL10n.text(.errorTerminalOpenFailed)
        case .appleScript(let value): value
        }
    }
}
#endif
