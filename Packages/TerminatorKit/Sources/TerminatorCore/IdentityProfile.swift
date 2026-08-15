import Foundation

public enum AuthenticationMethod: Codable, Hashable, Sendable {
    case password(secretID: SecretID)
    case accessKey(credentialID: UUID)

    public var credentialID: UUID? {
        guard case .accessKey(let id) = self else { return nil }
        return id
    }

    public var passwordSecretID: SecretID? {
        guard case .password(let id) = self else { return nil }
        return id
    }
}

public struct IdentityProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var username: String
    public var authenticationMethods: [AuthenticationMethod]
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, username, authenticationMethods, credentialIDs
        case createdAt, updatedAt, deletedAt
    }

    public init(
        id: UUID = UUID(),
        name: String,
        username: String,
        authenticationMethods: [AuthenticationMethod],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.authenticationMethods = authenticationMethods
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public init(
        id: UUID = UUID(),
        name: String,
        username: String,
        credentialIDs: [UUID],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.init(
            id: id,
            name: name,
            username: username,
            authenticationMethods: credentialIDs.map(AuthenticationMethod.accessKey),
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    public var isDeleted: Bool { deletedAt != nil }
    public var credentialIDs: [UUID] { authenticationMethods.compactMap(\.credentialID) }
    public var passwordSecretID: SecretID? { authenticationMethods.compactMap(\.passwordSecretID).first }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        username = try container.decode(String.self, forKey: .username)
        if let methods = try container.decodeIfPresent([AuthenticationMethod].self, forKey: .authenticationMethods) {
            authenticationMethods = methods
        } else {
            authenticationMethods = try container.decodeIfPresent([UUID].self, forKey: .credentialIDs)?
                .map(AuthenticationMethod.accessKey) ?? []
        }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(username, forKey: .username)
        try container.encode(authenticationMethods, forKey: .authenticationMethods)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }

    public func validated() throws -> IdentityProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Set(copy.authenticationMethods).count == copy.authenticationMethods.count else {
            throw IdentityValidationError.duplicateAuthenticationMethod
        }
        guard copy.authenticationMethods.filter({ $0.passwordSecretID != nil }).count <= 1 else {
            throw IdentityValidationError.multiplePasswords
        }
        return copy
    }
}

public enum IdentityValidationError: LocalizedError, Equatable, Sendable {
    case missingName
    case missingUsername
    case missingAuthenticationMethod
    case duplicateAuthenticationMethod
    case multiplePasswords
    case identityInUse

    public var errorDescription: String? {
        switch self {
        case .missingName: TerminatorCoreLocalization.text(.errorIdentityMissingName)
        case .missingUsername: TerminatorCoreLocalization.text(.errorIdentityMissingUsername)
        case .missingAuthenticationMethod: TerminatorCoreLocalization.text(.errorIdentityMissingAuthenticationMethod)
        case .duplicateAuthenticationMethod: TerminatorCoreLocalization.text(.errorCredentialDuplicateAuthenticationMethod)
        case .multiplePasswords: TerminatorCoreLocalization.text(.errorIdentityMultiplePasswords)
        case .identityInUse: TerminatorCoreLocalization.text(.errorIdentityInUse)
        }
    }
}
