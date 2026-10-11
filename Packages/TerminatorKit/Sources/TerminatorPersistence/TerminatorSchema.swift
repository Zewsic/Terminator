import Foundation
import SQLite3
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

public enum TerminatorSchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)
    public static var models: [any PersistentModel.Type] { [
        HostRecord.self,
        CredentialRecord.self,
        IdentityRecord.self,
        ChangeRecord.self,
        TerminatorSchemaV4.KnownHostRecord.self,
        SessionLogRecord.self,
    ] }

    // V4 shipped with one server key per endpoint. Keep this exact model frozen:
    // changing a type referenced by an old VersionedSchema makes existing stores
    // unrecognizable before a migration can even begin.
    @Model final class KnownHostRecord {
        @Attribute(.unique) var endpoint: String
        var id: UUID
        var algorithm: String
        var publicKey: Data
        var fingerprint: String
        var createdAt: Date
        var updatedAt: Date

        init(
            endpoint: String, id: UUID, algorithm: String, publicKey: Data,
            fingerprint: String, createdAt: Date, updatedAt: Date
        ) {
            self.endpoint = endpoint; self.id = id; self.algorithm = algorithm
            self.publicKey = publicKey; self.fingerprint = fingerprint
            self.createdAt = createdAt; self.updatedAt = updatedAt
        }
    }
}

public enum TerminatorSchemaV5: VersionedSchema {
    public static let versionIdentifier = Schema.Version(5, 0, 0)
    public static var models: [any PersistentModel.Type] { [
        HostRecord.self,
        CredentialRecord.self,
        IdentityRecord.self,
        ChangeRecord.self,
        KnownHostRecord.self,
        SessionLogRecord.self,
    ] }

    // V5 shipped without detectedOSData. Keep the historical model frozen so
    // SwiftData can recognize existing stores before migrating them to V6.
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
        var authenticationMethodsData: Data?
        var group: String?
        var tags: [String]
        var notes: String
        var sessionPersistenceRawValue: String = "none"
        var remoteShellPresetRawValue: String = "loginShell"
        var remoteShellCustomPath: String = ""
        var connectCommands: String = ""
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        init() {
            id = UUID(); displayName = ""; hostname = ""; port = 22; username = ""
            credentialID = nil; identityID = nil; group = nil; tags = []; notes = ""
            createdAt = .now; updatedAt = .now; deletedAt = nil
        }
    }
}

public enum TerminatorSchemaV6: VersionedSchema {
    public static let versionIdentifier = Schema.Version(6, 0, 0)
    public static var models: [any PersistentModel.Type] { [
        HostRecord.self,
        CredentialRecord.self,
        IdentityRecord.self,
        ChangeRecord.self,
        KnownHostRecord.self,
        SessionLogRecord.self,
    ] }
}

public enum TerminatorSchemaV7: VersionedSchema {
    public static let versionIdentifier = Schema.Version(7, 0, 0)
    public static var models: [any PersistentModel.Type] { TerminatorSchema.currentModels }
}

public enum TerminatorMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [
            TerminatorSchemaV1.self, TerminatorSchemaV2.self, TerminatorSchemaV3.self,
            TerminatorSchemaV4.self, TerminatorSchemaV5.self, TerminatorSchemaV6.self,
            TerminatorSchemaV7.self,
        ]
    }
    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: TerminatorSchemaV1.self, toVersion: TerminatorSchemaV2.self),
            .lightweight(fromVersion: TerminatorSchemaV2.self, toVersion: TerminatorSchemaV3.self),
            .lightweight(fromVersion: TerminatorSchemaV3.self, toVersion: TerminatorSchemaV4.self),
            .lightweight(fromVersion: TerminatorSchemaV4.self, toVersion: TerminatorSchemaV5.self),
            .lightweight(fromVersion: TerminatorSchemaV5.self, toVersion: TerminatorSchemaV6.self),
            .lightweight(fromVersion: TerminatorSchemaV6.self, toVersion: TerminatorSchemaV7.self),
        ]
    }
}

public enum TerminatorSchema {
    public static let version4 = Schema(versionedSchema: TerminatorSchemaV4.self)
    public static let version5 = Schema(versionedSchema: TerminatorSchemaV5.self)
    public static let version6 = Schema(versionedSchema: TerminatorSchemaV6.self)
    public static let version7 = Schema(versionedSchema: TerminatorSchemaV7.self)
    public static let currentModels: [any PersistentModel.Type] = [
        HostRecord.self,
        CredentialRecord.self,
        IdentityRecord.self,
        ChangeRecord.self,
        KnownHostRecord.self,
        SessionLogRecord.self,
        TunnelRecord.self,
    ]

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let versioned = Schema(versionedSchema: TerminatorSchemaV7.self)
        if inMemory {
            return try ModelContainer(
                for: versioned,
                migrationPlan: TerminatorMigrationPlan.self,
                configurations: [
                    ModelConfiguration("Terminator", schema: versioned, isStoredInMemoryOnly: true, allowsSave: true)
                ]
            )
        }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Terminator.store")
        try repairLegacyStoreIfNeeded(at: url)
        let versionedConfiguration = ModelConfiguration(
            "Terminator", schema: versioned, url: url, allowsSave: true
        )
        do {
            return try ModelContainer(
                for: versioned,
                migrationPlan: TerminatorMigrationPlan.self,
                configurations: [versionedConfiguration]
            )
        } catch {
            let inferred = Schema(currentModels)
            let inferredConfiguration = ModelConfiguration(
                "Terminator", schema: inferred, url: url, allowsSave: true
            )
            var metadataRepairContainer: ModelContainer? = try ModelContainer(
                for: inferred, configurations: [inferredConfiguration]
            )
            metadataRepairContainer = nil

            // The first inferred open normalizes model metadata but can rebuild
            // the table from the legacy physical schema. Close it, restore the
            // missing nullable column, then reopen against the now-current
            // metadata so Core Data cannot undo the repair asynchronously.
            try repairLegacyStoreIfNeeded(at: url)
            return try ModelContainer(for: inferred, configurations: [inferredConfiguration])
        }
    }

    static func repairLegacyStoreIfNeeded(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            defer { if let database { sqlite3_close(database) } }
            throw sqliteError(database, path: url.path)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 10_000)

        try execute("BEGIN EXCLUSIVE", on: database, path: url.path)
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT 1 FROM pragma_table_info('ZHOSTRECORD') WHERE name = 'ZDETECTEDOSDATA'",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw sqliteError(database, path: url.path)
            }
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) != SQLITE_ROW {
                try execute("ALTER TABLE ZHOSTRECORD ADD COLUMN ZDETECTEDOSDATA BLOB", on: database, path: url.path)
            }
            try execute("COMMIT", on: database, path: url.path)
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func execute(_ sql: String, on database: OpaquePointer, path: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(database, path: path)
        }
    }

    private static func sqliteError(_ database: OpaquePointer?, path: String) -> NSError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite store"
        return NSError(
            domain: "TerminatorPersistence.SQLite",
            code: database.map { Int(sqlite3_errcode($0)) } ?? Int(SQLITE_CANTOPEN),
            userInfo: [NSLocalizedDescriptionKey: message, NSFilePathErrorKey: path]
        )
    }
}
