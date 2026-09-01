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
        if isControlSocketLive() { return }
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
        if agent.status == .enabled {
            if await waitForService(attempts: 10) { return }
        }

        let canRepairRegistration = Date.now.timeIntervalSince(lastRegistrationRepair) >= 30
        if agent.status != .enabled || canRepairRegistration {
            lastRegistrationRepair = .now
            do {
                if agent.status == .enabled { try await agent.unregister() }
                try agent.register()
            } catch {
                spawnFallback()
            }
        }

        if await waitForService(attempts: 30) { return }
        spawnFallback()
        _ = await waitForService(attempts: 20)
    }

    private func waitForService(attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if isControlSocketLive() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
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
