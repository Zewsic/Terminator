import Foundation

public struct ConnectCommandSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var snippetID: UUID?

    public init(id: UUID = UUID(), text: String = "", snippetID: UUID? = nil) {
        self.id = id
        self.text = text
        self.snippetID = snippetID
    }

    public var isSnippet: Bool { snippetID != nil }
}

public enum ConnectCommandScript {
    /// Joins text and the current script of each linked snippet. A missing snippet contributes nothing.
    public static func render(_ segments: [ConnectCommandSegment], scripts: [UUID: String]) -> String {
        segments.map { segment in
            if let snippetID = segment.snippetID {
                return scripts[snippetID] ?? ""
            }
            return segment.text
        }.joined()
    }

    public static func stored(_ segments: [ConnectCommandSegment]) -> [ConnectCommandSegment] {
        segments.filter { segment in
            if segment.snippetID != nil { return true }
            return !segment.text.isEmpty
        }
    }
}
