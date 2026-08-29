import Foundation

public enum RemoteShellPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case loginShell
    case zsh
    case bash
    case sh
    case fish
    case custom

    public var id: String { rawValue }
}

public struct RemoteShell: Codable, Hashable, Sendable {
    public var preset: RemoteShellPreset
    public var customPath: String

    public static let login = RemoteShell(preset: .loginShell, customPath: "")

    public init(preset: RemoteShellPreset = .loginShell, customPath: String = "") {
        self.preset = preset
        self.customPath = customPath
    }
}
