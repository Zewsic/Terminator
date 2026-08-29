#if !APP_STORE
import Darwin
import Foundation
import ServiceManagement
import TerminatorCore
import TerminatorSSH

enum MCPAccessSupport {
    static func apply(enabled: Bool) {
        MCPClientInstaller.sync(enabled: enabled, commandPath: serviceURL.path)
    }

    static func refreshIfEnabled() {
        guard AccessPreferencesStore.load().mcpEnabled else { return }
        apply(enabled: true)
    }

    static var serviceURL: URL {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/terminator-service")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: "/Applications/Terminator.app/Contents/Helpers/terminator-service")
    }
}

enum ConnectionServiceSupport {
    static let agent = SMAppService.agent(plistName: "pro.zewsic.terminator.connection.plist")

    static func bootstrap() {
        Task.detached {
            await ensureRunning()
        }
    }

    static func ensureRunning() async {
        if isControlSocketLive() { return }
        try? FileManager.default.removeItem(at: ConnectionServicePaths.controlSocketURL)
        do {
            if agent.status == .enabled {
                try await agent.unregister()
            }
            try agent.register()
        } catch {
            spawnFallback()
        }
        for _ in 0..<30 {
            if isControlSocketLive() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        spawnFallback()
        for _ in 0..<20 {
            if isControlSocketLive() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func isControlSocketLive() -> Bool {
        let path = ConnectionServicePaths.controlSocketURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let length = min(path.utf8.count, MemoryLayout.size(ofValue: address.sun_path) - 1)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in path.utf8.prefix(length).enumerated() { bytes[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    private static func spawnFallback() {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/terminator-service")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else { return }
        let process = Process()
        process.executableURL = bundled
        process.qualityOfService = .userInitiated
        try? process.run()
    }
}

extension Notification.Name {
    static let terminatorRevealMainWindow = Notification.Name("pro.zewsic.terminator.revealMainWindow")
}
#endif
