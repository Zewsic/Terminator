import Foundation

public enum HistoryEntity: String, Codable, CaseIterable, Hashable, Sendable {
    case host
    case credential
    case identity
    case tunnel
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
        TerminatorCoreLocalization.text(.historyTitle, entity.displayName, operation.displayName)
    }
}

private extension HistoryEntity {
    var displayName: String {
        switch self {
        case .host: TerminatorCoreLocalization.text(.historyEntityHost)
        case .credential: TerminatorCoreLocalization.text(.historyEntityCredential)
        case .identity: TerminatorCoreLocalization.text(.hostUsernameIdentity)
        case .tunnel: TerminatorCoreLocalization.text(.historyEntityTunnel)
        }
    }
}

private extension HistoryOperation {
    var displayName: String {
        switch self {
        case .created: TerminatorCoreLocalization.text(.historyOperationCreated)
        case .updated: TerminatorCoreLocalization.text(.historyOperationUpdated)
        case .deleted: TerminatorCoreLocalization.text(.historyOperationDeleted)
        case .restored: TerminatorCoreLocalization.text(.historyOperationRestored)
        case .purged: TerminatorCoreLocalization.text(.historyOperationPurged)
        }
    }
}
