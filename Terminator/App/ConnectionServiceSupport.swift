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
    static func bootstrap() {
        Task { await ConnectionServiceSupervisor.shared.startMonitoring() }
    }

    static func ensureRunning() async {
        await ConnectionServiceSupervisor.shared.ensureRunning()
    }
}

private actor ConnectionServiceSupervisor {
    static let shared = ConnectionServiceSupervisor()

    private let agent = SMAppService.agent(plistName: "pro.zewsic.terminator.connection.plist")
    private var recoveryTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var lastRegistrationRepair = Date.distantPast

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.ensureRunning()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func ensureRunning() async {
        if isOurServiceRunning() { return }
        if let recoveryTask {
            await recoveryTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.recoverService()
        }
        recoveryTask = task
        await task.value
        recoveryTask = nil
    }

    private func recoverService() async {
        if isOurServiceRunning() { return }
        lastRegistrationRepair = .now
        terminateRunningService()
        try? await Task.sleep(for: .milliseconds(200))
        do {
            if agent.status == .enabled { try await agent.unregister() }
        } catch {}
        terminateRunningService()
        try? await Task.sleep(for: .milliseconds(150))
        spawnFallback()
        if await waitForOurService(attempts: 30) { return }
        do { try agent.register() } catch { spawnFallback() }
        _ = await waitForOurService(attempts: 20)
    }

    private func waitForOurService(attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if isOurServiceRunning() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func isOurServiceRunning() -> Bool {
        guard isControlSocketLive() else { return false }
        guard let running = runningServiceExecutable() else { return false }
        return running.resolvingSymlinksInPath().path == bundledHelperURL().resolvingSymlinksInPath().path
    }

    private func isControlSocketLive() -> Bool {
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

    private func bundledHelperURL() -> URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/terminator-service")
    }

    private func runningServiceExecutable() -> URL? {
        guard let pid = controlSocketPID() else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private func controlSocketPID() -> pid_t? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-t", ConnectionServicePaths.controlSocketURL.path]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let value = pid_t(line)
        else { return nil }
        return value
    }

    private func terminateRunningService() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-TERM", "terminator-service"]
        process.qualityOfService = .userInitiated
        try? process.run()
        process.waitUntilExit()
    }

    private func spawnFallback() {
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
