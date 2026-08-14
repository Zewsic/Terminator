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
    case accessKey
    case legacyPassphrase

    public var displayName: String {
        switch self {
        case .password: "Password"
        case .accessKey: "Access key"
        case .legacyPassphrase: "Legacy passphrase"
        }
    }
}

public enum ECDSACurve: String, Codable, CaseIterable, Hashable, Sendable {
    case p256
    case p384
    case p521

    public var displayName: String {
        switch self {
        case .p256: "P-256"
        case .p384: "P-384"
        case .p521: "P-521"
        }
    }

    public var sshName: String {
        switch self {
        case .p256: "nistp256"
        case .p384: "nistp384"
        case .p521: "nistp521"
        }
    }
}

public enum SSHKeyAlgorithm: Codable, Hashable, Sendable {
    case ed25519
    case ecdsa(ECDSACurve)
    case rsa(bitCount: Int)

    public var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsa(let curve): TerminatorCoreLocalization.text("algorithm.ecdsa", curve.displayName)
        case .rsa(let bitCount): TerminatorCoreLocalization.text("algorithm.rsa", bitCount)
        }
    }

    public var isLegacyCompatibility: Bool {
        if case .rsa(let bitCount) = self { return bitCount < 2_048 }
        return false
    }
}

public enum AccessKeyBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case software
    case secureEnclave

    public var displayName: String {
        switch self {
        case .software: "Software"
        case .secureEnclave: "Secure Enclave"
        }
    }
}

public enum AccessKeyOrigin: String, Codable, Hashable, Sendable {
    case imported
    case generated
    case migrated
}

public enum PassphraseProtection: Codable, Hashable, Sendable {
    case none
    case promptEveryConnection
    case saved(secretID: SecretID)

    public var savedSecretID: SecretID? {
        guard case .saved(let secretID) = self else { return nil }
        return secretID
    }

    public var requiresPassphrase: Bool {
        switch self {
        case .none: false
        case .promptEveryConnection, .saved: true
        }
    }

    public var displayName: String {
        switch self {
        case .none: "No passphrase"
        case .promptEveryConnection: "Ask every connection"
        case .saved: "Touch ID every connection"
        }
    }
}

public enum AccessKeyCompatibility: String, Codable, Hashable, Sendable {
    case current
    case legacyRSA1024
    case needsUpgrade

    public var warning: String? {
        switch self {
        case .current: nil
        case .legacyRSA1024: "RSA-1024 is retained only for legacy compatibility."
        case .needsUpgrade: "Open this key and provide its passphrase to finish migration."
        }
    }
}

public struct AccessKeyMetadata: Codable, Hashable, Sendable {
    public var algorithm: SSHKeyAlgorithm
    public var backend: AccessKeyBackend
    public var origin: AccessKeyOrigin
    public var publicKey: String
    public var fingerprint: String
    public var privateMaterialID: SecretID
    public var passphraseProtection: PassphraseProtection
    public var compatibility: AccessKeyCompatibility

    public init(
        algorithm: SSHKeyAlgorithm,
        backend: AccessKeyBackend,
        origin: AccessKeyOrigin,
        publicKey: String,
        fingerprint: String,
        privateMaterialID: SecretID = SecretID(),
        passphraseProtection: PassphraseProtection = .none,
        compatibility: AccessKeyCompatibility = .current
    ) {
        self.algorithm = algorithm
        self.backend = backend
        self.origin = origin
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.privateMaterialID = privateMaterialID
        self.passphraseProtection = passphraseProtection
        self.compatibility = compatibility
    }
}

public struct CredentialMetadata: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var kind: CredentialKind
    public var secretID: SecretID
    public var accessKey: AccessKeyMetadata?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var secretPurgedAt: Date?

    public init(
        id: UUID = UUID(),
        label: String,
        kind: CredentialKind,
        secretID: SecretID = SecretID(),
        accessKey: AccessKeyMetadata? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil,
        secretPurgedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.secretID = secretID
        self.accessKey = accessKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.secretPurgedAt = secretPurgedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
    public var isSecretAvailable: Bool { secretPurgedAt == nil }

    public var fingerprint: String? { accessKey?.fingerprint }

    private enum CodingKeys: String, CodingKey {
        case id, label, kind, secretID, accessKey, fingerprint
        case createdAt, updatedAt, deletedAt, secretPurgedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        secretID = try container.decode(SecretID.self, forKey: .secretID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        secretPurgedAt = try container.decodeIfPresent(Date.self, forKey: .secretPurgedAt)
        accessKey = try container.decodeIfPresent(AccessKeyMetadata.self, forKey: .accessKey)

        if let current = try? container.decode(CredentialKind.self, forKey: .kind) {
            kind = current
        } else {
            let legacy = try container.decode(String.self, forKey: .kind)
            switch legacy {
            case "privateKey": kind = .accessKey
            case "keyPassphrase": kind = .legacyPassphrase
            default: kind = .password
            }
        }

        if kind == .accessKey, accessKey == nil {
            let fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? "Unknown"
            accessKey = AccessKeyMetadata(
                algorithm: .ed25519,
                backend: .software,
                origin: .migrated,
                publicKey: "Legacy key — upgrade required",
                fingerprint: fingerprint,
                privateMaterialID: secretID,
                compatibility: .needsUpgrade
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(kind, forKey: .kind)
        try container.encode(secretID, forKey: .secretID)
        try container.encodeIfPresent(accessKey, forKey: .accessKey)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encodeIfPresent(secretPurgedAt, forKey: .secretPurgedAt)
    }

    public var allSecretIDs: [SecretID] {
        var ids = [secretID]
        if let materialID = accessKey?.privateMaterialID, materialID != secretID {
            ids.append(materialID)
        }
        if let passphraseID = accessKey?.passphraseProtection.savedSecretID {
            ids.append(passphraseID)
        }
        return ids
    }

    public func validated() throws -> CredentialMetadata {
        var copy = self
        copy.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.label.isEmpty else { throw CredentialValidationError.missingLabel }

        switch copy.kind {
        case .password, .legacyPassphrase:
            guard copy.accessKey == nil else { throw CredentialValidationError.unexpectedAccessKeyMetadata }
        case .accessKey:
            guard var key = copy.accessKey else { throw CredentialValidationError.missingAccessKeyMetadata }
            key.publicKey = key.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            key.fingerprint = key.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.publicKey.isEmpty else { throw CredentialValidationError.missingPublicKey }
            guard !key.fingerprint.isEmpty else { throw CredentialValidationError.missingFingerprint }
            if key.backend == .secureEnclave {
                guard key.algorithm == .ecdsa(.p256) else {
                    throw CredentialValidationError.invalidSecureEnclaveAlgorithm
                }
                guard key.passphraseProtection == .none else {
                    throw CredentialValidationError.invalidSecureEnclavePassphrase
                }
            }
            if case .rsa(let bitCount) = key.algorithm, bitCount < 1_024 {
                throw CredentialValidationError.invalidRSAKeySize
            }
            copy.accessKey = key
        }
        return copy
    }
}

public enum CredentialValidationError: LocalizedError, Equatable, Sendable {
    case missingLabel
    case missingSecret
    case missingAccessKeyMetadata
    case unexpectedAccessKeyMetadata
    case missingPublicKey
    case missingFingerprint
    case invalidSecureEnclaveAlgorithm
    case invalidSecureEnclavePassphrase
    case invalidRSAKeySize
    case duplicateAuthenticationMethod
    case referencedCredentialUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingLabel: "A credential label is required."
        case .missingSecret: "A secret value is required."
        case .missingAccessKeyMetadata: "Access-key metadata is required."
        case .unexpectedAccessKeyMetadata: "Only access keys may contain key metadata."
        case .missingPublicKey: "A public key is required."
        case .missingFingerprint: "A public-key fingerprint is required."
        case .invalidSecureEnclaveAlgorithm: "Secure Enclave keys must use ECDSA P-256."
        case .invalidSecureEnclavePassphrase: "Secure Enclave keys cannot use a passphrase."
        case .invalidRSAKeySize: "RSA keys must contain at least 1024 bits."
        case .duplicateAuthenticationMethod: "An authentication method can appear only once."
        case .referencedCredentialUnavailable: "A referenced credential is unavailable."
        }
    }
}
