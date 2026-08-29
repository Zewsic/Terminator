#if os(macOS)
import AppKit
import Darwin
import Foundation
import TerminatorCore
import TerminatorSSH

struct ServiceTerminalLauncher: ConnectionTerminalLaunching {
    private static let parentBundleID = "pro.zewsic.terminator"

    func attachHelperURL() throws -> URL {
        if let helper = helperCandidates().first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return helper
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [
            NSLocalizedDescriptionKey: "terminator-attach is not next to terminator-service",
        ])
    }

    private func helperCandidates() -> [URL] {
        var directories: [URL] = []
        if let executable = currentExecutableURL() {
            directories.append(executable.deletingLastPathComponent())
        }
        if let app = terminatorAppURL() {
            directories.append(app.appending(path: "Contents/Helpers", directoryHint: .isDirectory))
        }
        directories.append(contentsOf: debugBuildDirectories())
        return directories.map { $0.appending(path: "terminator-attach") }
    }

    private func terminatorAppURL() -> URL? {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.parentBundleID) {
            return app
        }
        let applications = URL(fileURLWithPath: "/Applications/Terminator.app")
        if FileManager.default.fileExists(atPath: applications.path) { return applications }
        return parentAppFromExecutable()
    }

    private func parentAppFromExecutable() -> URL? {
        guard var url = currentExecutableURL() else { return nil }
        for _ in 0..<8 {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(max(1, size)))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let raw = String(cString: buffer)
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: raw)
        return url.resolvingSymlinksInPath()
    }

    private func debugBuildDirectories() -> [URL] {
        let file = URL(fileURLWithPath: #filePath)
        let packageRoot = file.deletingLastPathComponent().deletingLastPathComponent()
        return [
            packageRoot.appending(path: ".build/debug", directoryHint: .isDirectory),
            packageRoot.appending(path: ".build/arm64-apple-macosx/debug", directoryHint: .isDirectory),
        ]
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
            try runAppleScript(
                "tell application \"iTerm\" to create window with default profile command \(appleScriptString(command))"
            )
        case .ghostty:
            try launchCommandFile(command, applicationBundleID: "com.mitchellh.ghostty")
        case .wezTerm:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.wez.wezterm") else {
                throw LaunchError.notInstalled
            }
            let executable = app.appending(path: "Contents/MacOS/wezterm")
            let process = Process()
            process.executableURL = executable
            process.arguments = ["start", "--", "/bin/zsh", "-lc", command]
            try process.run()
        case .warp:
            try launchWarp(command: command, descriptor: descriptor)
        }
    }

    func revealTerminator() async {
        let notification = Notification.Name(TerminatorDistributedNotification.revealGUI)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.parentBundleID)
        if let app = running.first(where: { !$0.isTerminated }) {
            DistributedNotificationCenter.default().post(name: notification, object: nil)
            _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }
        guard let appURL = terminatorAppURL() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        DistributedNotificationCenter.default().post(name: notification, object: nil)
    }

    @MainActor
    private func launchWarp(command: String, descriptor: AttachDescriptor) throws {
        let identifiers = ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp"]
        guard identifiers.contains(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) else {
            throw LaunchError.notInstalled
        }
        let name = "Terminator-\(descriptor.sessionID.uuidString)"
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".warp/launch_configurations", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
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
        guard let url = URL(string: "warp://launch/\(name)") else { throw LaunchError.invalidURL }
        guard NSWorkspace.shared.open(url) else { throw LaunchError.openFailed }
        Task {
            try? await Task.sleep(for: .seconds(5))
            try? FileManager.default.removeItem(at: file)
        }
    }

    @MainActor
    private func launchCommandFile(_ command: String, applicationBundleID: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TerminatorAttach-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appending(path: "Connect.command")
        let quoted = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/zsh\n\(command)\nstatus=$?\nrm -rf -- \(quoted)\nexit $status\n"
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: applicationBundleID) else {
            throw LaunchError.notInstalled
        }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    private func runAppleScript(_ source: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw LaunchError.appleScript(error.description) }
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

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
