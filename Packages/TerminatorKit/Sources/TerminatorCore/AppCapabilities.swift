public struct AppCapabilities: Equatable, Sendable {
    public var localShell: Bool
    public var externalFileAccess: Bool
    public var externalTerminal: Bool
    public var isAppStoreBuild: Bool

    public init(localShell: Bool, externalFileAccess: Bool, externalTerminal: Bool, isAppStoreBuild: Bool) {
        self.localShell = localShell
        self.externalFileAccess = externalFileAccess
        self.externalTerminal = externalTerminal
        self.isAppStoreBuild = isAppStoreBuild
    }

    public static let direct = AppCapabilities(
        localShell: true,
        externalFileAccess: true,
        externalTerminal: true,
        isAppStoreBuild: false
    )

    public static let appStore = AppCapabilities(
        localShell: false,
        externalFileAccess: false,
        externalTerminal: false,
        isAppStoreBuild: true
    )
}
