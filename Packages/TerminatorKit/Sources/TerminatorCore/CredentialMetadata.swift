import Foundation

public struct SecretID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public enum CredentialKind: String, Codable, CaseIterable, Hashable, Sendable {
    case password
    case privateKey
    case keyPassphrase

    public var displayName: String {
        switch self {
        case .password: "Password"
        case .privateKey: "Private key"
        case .keyPassphrase: "Key passphrase"
        }
    }
}

public struct CredentialMetadata: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var kind: CredentialKind
    public var secretID: SecretID
    public var fingerprint: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var secretPurgedAt: Date?

    public init(
        id: UUID = UUID(),
        label: String,
        kind: CredentialKind,
        secretID: SecretID = SecretID(),
        fingerprint: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil,
        secretPurgedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.secretID = secretID
        self.fingerprint = fingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.secretPurgedAt = secretPurgedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
    public var isSecretAvailable: Bool { secretPurgedAt == nil }

    public func validated() throws -> CredentialMetadata {
        var copy = self
        copy.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.fingerprint = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.label.isEmpty else { throw CredentialValidationError.missingLabel }
        return copy
    }
}

public enum CredentialValidationError: LocalizedError, Equatable, Sendable {
    case missingLabel
    case missingSecret

    public var errorDescription: String? {
        switch self {
        case .missingLabel: "A credential label is required."
        case .missingSecret: "A secret value is required."
        }
    }
}
