import Foundation
import TerminatorCore

struct SnippetDraft: Equatable, Identifiable, Sendable {
    var id: UUID?
    var name: String
    var script: String
    var group: String
    var tagsText: String
    var notes: String

    init(snippet: SnippetProfile? = nil) {
        id = snippet?.id
        name = snippet?.name ?? ""
        script = snippet?.script ?? ""
        group = snippet?.group ?? ""
        tagsText = snippet?.tags.joined(separator: ", ") ?? ""
        notes = snippet?.notes ?? ""
    }

    var tags: [String] {
        tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func duplicate() -> SnippetDraft {
        var copy = self
        copy.id = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = trimmed.isEmpty ? trimmed : "\(trimmed) copy"
        return copy
    }
}
