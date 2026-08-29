import Foundation

public enum SessionPersistence: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case tmux
    case screen

    public var id: String { rawValue }
}
