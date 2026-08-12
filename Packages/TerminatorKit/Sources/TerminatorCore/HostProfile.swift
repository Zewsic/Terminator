import Foundation

public struct HostProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var group: String?
    public var tags: [String]
    public var notes: String
    public var credentialID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: Int = 22,
        username: String,
        group: String? = nil,
        tags: [String] = [],
        notes: String = "",
        credentialID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.group = group
        self.tags = tags
        self.notes = notes
        self.credentialID = credentialID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }

    public func validated() throws -> HostProfile {
        var copy = self
        copy.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.group = group?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        copy.tags = Array(
            Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        ).sorted()

        guard !copy.displayName.isEmpty else { throw HostValidationError.missingDisplayName }
        guard !copy.hostname.isEmpty else { throw HostValidationError.missingHostname }
        guard !copy.username.isEmpty else { throw HostValidationError.missingUsername }
        guard (1...65_535).contains(copy.port) else { throw HostValidationError.invalidPort }
        return copy
    }
}

public enum HostValidationError: LocalizedError, Equatable, Sendable {
    case missingDisplayName
    case missingHostname
    case missingUsername
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .missingDisplayName: "A display name is required."
        case .missingHostname: "A hostname is required."
        case .missingUsername: "A username is required."
        case .invalidPort: "The port must be between 1 and 65535."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
