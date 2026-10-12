import Foundation

public struct SnippetProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var script: String
    public var group: String?
    public var tags: [String]
    public var notes: String
    public var lastUsedAt: Date?
    public var externalID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        script: String,
        group: String? = nil,
        tags: [String] = [],
        notes: String = "",
        lastUsedAt: Date? = nil,
        externalID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.script = script
        self.group = group
        self.tags = tags
        self.notes = notes
        self.lastUsedAt = lastUsedAt
        self.externalID = externalID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }

    public func validated() throws -> SnippetProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.group = group?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        copy.tags = Array(
            Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        ).sorted()
        copy.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { throw SnippetValidationError.missingName }
        guard !copy.script.isEmpty else { throw SnippetValidationError.missingScript }
        return copy
    }
}

public enum SnippetValidationError: LocalizedError, Equatable, Sendable {
    case missingName
    case missingScript

    public var errorDescription: String? {
        switch self {
        case .missingName: TerminatorCoreLocalization.text(.errorSnippetMissingName)
        case .missingScript: TerminatorCoreLocalization.text(.errorSnippetMissingScript)
        }
    }
}

public struct ExternalImportSnippet: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var script: String
    public var group: String
    public var tags: [String]
    public var notes: String

    public init(id: String, label: String, script: String, group: String = "", tags: [String] = [], notes: String = "") {
        self.id = id
        self.label = label
        self.script = script
        self.group = group
        self.tags = tags
        self.notes = notes
    }
}

public struct HostActionResult: Equatable, Sendable {
    public var succeeded: Bool
    public var message: String

    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded
        self.message = message
    }
}

public protocol ActivityLogRecording: Sendable {
    func record(host: HostProfile, title: String, output: String, displayName: String?) async
}

extension ActivityLogRecording {
    public func record(host: HostProfile, title: String, output: String) async {
        await record(host: host, title: title, output: output, displayName: nil)
    }
}
