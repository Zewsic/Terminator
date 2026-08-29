import Foundation

public struct AccessPreferences: Codable, Equatable, Sendable {
    public var cliEnabled: Bool
    public var mcpEnabled: Bool

    public static let `default` = AccessPreferences(cliEnabled: true, mcpEnabled: false)

    public init(cliEnabled: Bool = true, mcpEnabled: Bool = false) {
        self.cliEnabled = cliEnabled
        self.mcpEnabled = mcpEnabled
    }
}

public enum AccessPreferencesStore: Sendable {
    public static var url: URL {
        ConnectionServicePaths.applicationSupport.appending(path: "access.json")
    }

    public static func load() -> AccessPreferences {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(AccessPreferences.self, from: data) else {
            return .default
        }
        return value
    }

    public static func save(_ value: AccessPreferences) {
        try? FileManager.default.createDirectory(
            at: ConnectionServicePaths.applicationSupport, withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        DistributedNotificationCenter.default().post(
            name: Notification.Name(TerminatorDistributedNotification.accessChanged), object: nil
        )
    }
}
