public struct AppCapabilities: Equatable, Sendable {
    public var localShell: Bool
    public var externalFileAccess: Bool
    public var isAppStoreBuild: Bool

    public init(localShell: Bool, externalFileAccess: Bool, isAppStoreBuild: Bool) {
        self.localShell = localShell
        self.externalFileAccess = externalFileAccess
        self.isAppStoreBuild = isAppStoreBuild
    }

    public static let direct = AppCapabilities(
        localShell: true,
        externalFileAccess: true,
        isAppStoreBuild: false
    )

    public static let appStore = AppCapabilities(
        localShell: false,
        externalFileAccess: false,
        isAppStoreBuild: true
    )
}
