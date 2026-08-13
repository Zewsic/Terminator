import Foundation
import SwiftData

public enum TerminatorSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [HostRecord.self, CredentialRecord.self, ChangeRecord.self]
    }

    @Model public final class HostRecord {
        @Attribute(.unique) public var id: UUID
        var displayName: String
        var hostname: String
        var port: Int
        var username: String
        var group: String?
        var tags: [String]
        var notes: String
        var credentialID: UUID?
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        public init(id: UUID, displayName: String, hostname: String, port: Int, username: String,
             group: String?, tags: [String], notes: String, credentialID: UUID?,
             createdAt: Date, updatedAt: Date, deletedAt: Date?) {
            self.id = id; self.displayName = displayName; self.hostname = hostname; self.port = port
            self.username = username; self.group = group; self.tags = tags; self.notes = notes
            self.credentialID = credentialID; self.createdAt = createdAt; self.updatedAt = updatedAt
            self.deletedAt = deletedAt
        }
    }

    @Model public final class CredentialRecord {
        @Attribute(.unique) public var id: UUID
        var label: String
        var kindRawValue: String
        var secretID: UUID
        var fingerprint: String?
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?
        var secretPurgedAt: Date?

        public init(id: UUID, label: String, kindRawValue: String, secretID: UUID, fingerprint: String?,
             createdAt: Date, updatedAt: Date, deletedAt: Date?, secretPurgedAt: Date?) {
            self.id = id; self.label = label; self.kindRawValue = kindRawValue; self.secretID = secretID
            self.fingerprint = fingerprint; self.createdAt = createdAt; self.updatedAt = updatedAt
            self.deletedAt = deletedAt; self.secretPurgedAt = secretPurgedAt
        }
    }

    @Model public final class ChangeRecord {
        @Attribute(.unique) public var id: UUID
        var entityRawValue: String
        var entityID: UUID
        var operationRawValue: String
        var timestamp: Date
        var schemaVersion: Int
        var beforeSnapshot: Data?
        var afterSnapshot: Data?
        var source: String

        public init(id: UUID, entityRawValue: String, entityID: UUID, operationRawValue: String,
             timestamp: Date, schemaVersion: Int, beforeSnapshot: Data?, afterSnapshot: Data?, source: String) {
            self.id = id; self.entityRawValue = entityRawValue; self.entityID = entityID
            self.operationRawValue = operationRawValue; self.timestamp = timestamp
            self.schemaVersion = schemaVersion; self.beforeSnapshot = beforeSnapshot
            self.afterSnapshot = afterSnapshot; self.source = source
        }
    }
}

public enum TerminatorSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [HostRecord.self, CredentialRecord.self, IdentityRecord.self, ChangeRecord.self]
    }

    @Model final class HostRecord {
        @Attribute(.unique) var id: UUID
        var displayName: String
        var hostname: String
        var port: Int
        var username: String
        var credentialID: UUID?
        var authenticationModeRawValue: String = "manual"
        var identityID: UUID?
        var credentialIDs: [UUID] = []
        var group: String?
        var tags: [String]
        var notes: String
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        init() {
            id = UUID(); displayName = ""; hostname = ""; port = 22; username = ""
            credentialID = nil; identityID = nil; group = nil; tags = []; notes = ""
            createdAt = .now; updatedAt = .now; deletedAt = nil
        }
    }

    @Model final class CredentialRecord {
        @Attribute(.unique) var id: UUID
        var label: String
        var kindRawValue: String
        var secretID: UUID
        var fingerprint: String?
        var accessKeyData: Data?
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?
        var secretPurgedAt: Date?

        init() {
            id = UUID(); label = ""; kindRawValue = "password"; secretID = UUID()
            fingerprint = nil; accessKeyData = nil; createdAt = .now; updatedAt = .now
            deletedAt = nil; secretPurgedAt = nil
        }
    }

    @Model final class IdentityRecord {
        @Attribute(.unique) var id: UUID
        var name: String
        var username: String
        var credentialIDs: [UUID]
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        init() {
            id = UUID(); name = ""; username = ""; credentialIDs = []
            createdAt = .now; updatedAt = .now; deletedAt = nil
        }
    }

    @Model final class ChangeRecord {
        @Attribute(.unique) var id: UUID
        var entityRawValue: String
        var entityID: UUID
        var operationRawValue: String
        var timestamp: Date
        var schemaVersion: Int
        var beforeSnapshot: Data?
        var afterSnapshot: Data?
        var source: String

        init() {
            id = UUID(); entityRawValue = "host"; entityID = UUID(); operationRawValue = "created"
            timestamp = .now; schemaVersion = 2; beforeSnapshot = nil; afterSnapshot = nil; source = "user"
        }
    }
}

public enum TerminatorSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)
    public static var models: [any PersistentModel.Type] { [
        HostRecord.self,
        CredentialRecord.self,
        IdentityRecord.self,
        ChangeRecord.self,
    ] }
}

public enum TerminatorMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [TerminatorSchemaV1.self, TerminatorSchemaV2.self, TerminatorSchemaV3.self]
    }
    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: TerminatorSchemaV1.self, toVersion: TerminatorSchemaV2.self),
            .lightweight(fromVersion: TerminatorSchemaV2.self, toVersion: TerminatorSchemaV3.self),
        ]
    }
}

public enum TerminatorSchema {
    public static let version3 = Schema(versionedSchema: TerminatorSchemaV3.self)

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Terminator",
            schema: version3,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true
        )
        return try ModelContainer(
            for: version3,
            migrationPlan: TerminatorMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
