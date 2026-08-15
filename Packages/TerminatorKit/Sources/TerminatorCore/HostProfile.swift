import Foundation

public enum HostAuthentication: Codable, Hashable, Sendable {
    case identity(UUID)
    case manual(username: String, authenticationMethods: [AuthenticationMethod])

    public var identityID: UUID? {
        guard case .identity(let id) = self else { return nil }
        return id
    }

    public var manualUsername: String? {
        guard case .manual(let username, _) = self else { return nil }
        return username
    }

    public var credentialIDs: [UUID] {
        guard case .manual(_, let methods) = self else { return [] }
        return methods.compactMap(\.credentialID)
    }

    public var authenticationMethods: [AuthenticationMethod] {
        guard case .manual(_, let methods) = self else { return [] }
        return methods
    }

    private enum CodingKeys: String, CodingKey { case identity, manual }
    private enum IdentityKeys: String, CodingKey { case value = "_0" }
    private enum ManualKeys: String, CodingKey { case username, authenticationMethods, credentialIDs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.identity) {
            let nested = try container.nestedContainer(keyedBy: IdentityKeys.self, forKey: .identity)
            self = .identity(try nested.decode(UUID.self, forKey: .value))
        } else {
            let nested = try container.nestedContainer(keyedBy: ManualKeys.self, forKey: .manual)
            let username = try nested.decode(String.self, forKey: .username)
            let methods = try nested.decodeIfPresent([AuthenticationMethod].self, forKey: .authenticationMethods)
                ?? nested.decodeIfPresent([UUID].self, forKey: .credentialIDs)?.map(AuthenticationMethod.accessKey)
                ?? []
            self = .manual(username: username, authenticationMethods: methods)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .identity(let id):
            var nested = container.nestedContainer(keyedBy: IdentityKeys.self, forKey: .identity)
            try nested.encode(id, forKey: .value)
        case .manual(let username, let methods):
            var nested = container.nestedContainer(keyedBy: ManualKeys.self, forKey: .manual)
            try nested.encode(username, forKey: .username)
            try nested.encode(methods, forKey: .authenticationMethods)
        }
    }
}

public struct HostProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var authentication: HostAuthentication
    public var group: String?
    public var tags: [String]
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: Int = 22,
        authentication: HostAuthentication,
        group: String? = nil,
        tags: [String] = [],
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.authentication = authentication
        self.group = group
        self.tags = tags
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Compatibility initializer for pre-identity callers and migration fixtures.
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
        self.init(
            id: id,
            displayName: displayName,
            hostname: hostname,
            port: port,
            authentication: .manual(
                username: username,
                authenticationMethods: credentialID.map { [.accessKey(credentialID: $0)] } ?? []
            ),
            group: group,
            tags: tags,
            notes: notes,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    public var isDeleted: Bool { deletedAt != nil }

    public var username: String {
        authentication.manualUsername ?? "Identity"
    }

    public var credentialID: UUID? { authentication.credentialIDs.first }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, hostname, port, authentication, username, credentialID
        case group, tags, notes, createdAt, updatedAt, deletedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decode(Int.self, forKey: .port)
        if let current = try container.decodeIfPresent(HostAuthentication.self, forKey: .authentication) {
            authentication = current
        } else {
            let username = try container.decode(String.self, forKey: .username)
            let credentialID = try container.decodeIfPresent(UUID.self, forKey: .credentialID)
            authentication = .manual(
                username: username,
                authenticationMethods: credentialID.map { [.accessKey(credentialID: $0)] } ?? []
            )
        }
        group = try container.decodeIfPresent(String.self, forKey: .group)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(port, forKey: .port)
        try container.encode(authentication, forKey: .authentication)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(tags, forKey: .tags)
        try container.encode(notes, forKey: .notes)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }

    public func validated() throws -> HostProfile {
        var copy = self
        copy.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.group = group?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        copy.tags = Array(
            Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        ).sorted()

        guard !copy.displayName.isEmpty else { throw HostValidationError.missingDisplayName }
        guard !copy.hostname.isEmpty else { throw HostValidationError.missingHostname }
        guard (1...65_535).contains(copy.port) else { throw HostValidationError.invalidPort }

        switch copy.authentication {
        case .identity:
            break
        case .manual(let username, let methods):
            let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Set(methods).count == methods.count else {
                throw HostValidationError.duplicateAuthenticationMethod
            }
            guard methods.filter({ $0.passwordSecretID != nil }).count <= 1 else {
                throw HostValidationError.duplicateAuthenticationMethod
            }
            copy.authentication = .manual(username: username, authenticationMethods: methods)
        }
        return copy
    }
}

public enum HostValidationError: LocalizedError, Equatable, Sendable {
    case missingDisplayName
    case missingHostname
    case missingUsername
    case invalidPort
    case duplicateAuthenticationMethod
    case referencedIdentityUnavailable
    case referencedCredentialUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingDisplayName: TerminatorCoreLocalization.text(.errorHostMissingDisplayName)
        case .missingHostname: TerminatorCoreLocalization.text(.errorHostMissingHostname)
        case .missingUsername: TerminatorCoreLocalization.text(.errorHostMissingUsername)
        case .invalidPort: TerminatorCoreLocalization.text(.errorHostInvalidPort)
        case .duplicateAuthenticationMethod: TerminatorCoreLocalization.text(.errorCredentialDuplicateAuthenticationMethod)
        case .referencedIdentityUnavailable: TerminatorCoreLocalization.text(.errorHostReferencedIdentityUnavailable)
        case .referencedCredentialUnavailable: TerminatorCoreLocalization.text(.errorHostReferencedCredentialUnavailable)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
