import Foundation

public enum HistoryEntity: String, Codable, CaseIterable, Hashable, Sendable {
    case host
    case credential
    case identity
}

public enum HistoryOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case created
    case updated
    case deleted
    case restored
    case purged
}

public struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var entity: HistoryEntity
    public var entityID: UUID
    public var operation: HistoryOperation
    public var timestamp: Date
    public var schemaVersion: Int
    public var beforeSnapshot: Data?
    public var afterSnapshot: Data?
    public var source: String

    public init(
        id: UUID = UUID(),
        entity: HistoryEntity,
        entityID: UUID,
        operation: HistoryOperation,
        timestamp: Date = .now,
        schemaVersion: Int = 3,
        beforeSnapshot: Data?,
        afterSnapshot: Data?,
        source: String = "user"
    ) {
        self.id = id
        self.entity = entity
        self.entityID = entityID
        self.operation = operation
        self.timestamp = timestamp
        self.schemaVersion = schemaVersion
        self.beforeSnapshot = beforeSnapshot
        self.afterSnapshot = afterSnapshot
        self.source = source
    }

    public var title: String {
        TerminatorCoreLocalization.text("history.title", entity.displayName, operation.displayName)
    }
}

private extension HistoryEntity {
    var displayName: String {
        switch self {
        case .host: "Host"
        case .credential: "Credential"
        case .identity: "Identity"
        }
    }
}

private extension HistoryOperation {
    var displayName: String {
        switch self {
        case .created: "created"
        case .updated: "updated"
        case .deleted: "deleted"
        case .restored: "restored"
        case .purged: "purged"
        }
    }
}
