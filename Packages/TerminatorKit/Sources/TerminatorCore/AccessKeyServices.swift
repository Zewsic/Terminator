import Foundation

public enum SoftwareKeyGeneration: Equatable, Sendable {
    case ed25519
    case ecdsa(ECDSACurve)
    case rsa(bitCount: Int)

    public var algorithm: SSHKeyAlgorithm {
        switch self {
        case .ed25519: .ed25519
        case .ecdsa(let curve): .ecdsa(curve)
        case .rsa(let bitCount): .rsa(bitCount: bitCount)
        }
    }
}

public struct AccessKeyGenerationRequest: Equatable, Sendable {
    public var algorithm: SoftwareKeyGeneration
    public var comment: String
    public var passphrase: String

    public init(algorithm: SoftwareKeyGeneration, comment: String = "", passphrase: String = "") {
        self.algorithm = algorithm
        self.comment = comment
        self.passphrase = passphrase
    }
}

public struct AccessKeyImportRequest: Equatable, Sendable {
    public var privateKey: String
    public var suppliedPublicKey: String
    public var passphrase: String

    public init(privateKey: String, suppliedPublicKey: String = "", passphrase: String = "") {
        self.privateKey = privateKey
        self.suppliedPublicKey = suppliedPublicKey
        self.passphrase = passphrase
    }
}

public struct PreparedAccessKey: Equatable, Sendable {
    public var privateMaterial: Data
    public var algorithm: SSHKeyAlgorithm
    public var backend: AccessKeyBackend
    public var publicKey: String
    public var fingerprint: String
    public var isPassphraseProtected: Bool
    public var compatibility: AccessKeyCompatibility

    public init(
        privateMaterial: Data,
        algorithm: SSHKeyAlgorithm,
        backend: AccessKeyBackend,
        publicKey: String,
        fingerprint: String,
        isPassphraseProtected: Bool,
        compatibility: AccessKeyCompatibility = .current
    ) {
        self.privateMaterial = privateMaterial
        self.algorithm = algorithm
        self.backend = backend
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.isPassphraseProtected = isPassphraseProtected
        self.compatibility = compatibility
    }
}

public protocol AccessKeyService: Sendable {
    func generateSoftwareKey(_ request: AccessKeyGenerationRequest) async throws -> PreparedAccessKey
    func importSoftwareKey(_ request: AccessKeyImportRequest) async throws -> PreparedAccessKey
    func generateSecureEnclaveKey(label: String) async throws -> PreparedAccessKey
    func exportSoftwareKey(privateMaterial: Data, passphrase: String) async throws -> Data
    func decodeSoftwareKey(privateMaterial: Data, passphrase: String) async throws -> SSHPrivateKeyMaterial
}

public protocol UserPresenceAuthorizer: Sendable {
    func authorize(reason: String) async throws
}

public struct ConnectionAuthenticationChoice: Codable, Equatable, Sendable {
    public var username: String
    public var identityID: UUID?
    public var password: String?
    public var credentialID: UUID?

    public init(
        username: String = "",
        identityID: UUID? = nil,
        password: String? = nil,
        credentialID: UUID? = nil
    ) {
        self.username = username
        self.identityID = identityID
        self.password = password
        self.credentialID = credentialID
    }
}

public protocol CredentialPrompting: Sendable {
    func requestPassphrase(for credential: CredentialMetadata) async throws -> String
    func requestUsername(for host: HostProfile) async throws -> String
    func requestPassword(for host: HostProfile, username: String) async throws -> String
    func requestAuthentication(
        for host: HostProfile,
        username: String,
        availableAccessKeys: [CredentialMetadata],
        availableIdentities: [IdentityProfile]
    ) async throws -> ConnectionAuthenticationChoice
}

public extension CredentialPrompting {
    func requestAuthentication(
        for host: HostProfile,
        username: String,
        availableAccessKeys: [CredentialMetadata],
        availableIdentities: [IdentityProfile]
    ) async throws -> ConnectionAuthenticationChoice {
        let resolvedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? try await requestUsername(for: host)
            : username
        return .init(
            username: resolvedUsername,
            password: try await requestPassword(for: host, username: resolvedUsername)
        )
    }
}

public enum ResolvedAuthenticationMethod: Sendable {
    case password(credentialID: UUID, value: Data)
    case softwareKey(credentialID: UUID, privateMaterial: Data, passphrase: String?)
    case secureEnclaveKey(credentialID: UUID, keyReference: Data)
}

public struct ResolvedSSHIdentity: Sendable {
    public var username: String
    public var methods: [ResolvedAuthenticationMethod]

    public init(username: String, methods: [ResolvedAuthenticationMethod]) {
        self.username = username
        self.methods = methods
    }
}

public protocol AuthenticationResolving: Sendable {
    func resolve(host: HostProfile, prompting: any CredentialPrompting) async throws -> ResolvedSSHIdentity
}

public enum AccessKeyServiceError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case encryptedLegacyFormatUnsupported
    case invalidPrivateKey
    case invalidPassphrase
    case publicKeyMismatch
    case invalidRSAKeySize
    case secureEnclaveUnavailable
    case secureEnclaveKeyIsNotExportable
    case authorizationCancelled
    case passphraseRequired

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: TerminatorCoreLocalization.text(.errorAccessKeyUnsupportedFormat)
        case .encryptedLegacyFormatUnsupported: TerminatorCoreLocalization.text(.errorAccessKeyEncryptedLegacyFormatUnsupported)
        case .invalidPrivateKey: TerminatorCoreLocalization.text(.errorAccessKeyInvalidPrivateKey)
        case .invalidPassphrase: TerminatorCoreLocalization.text(.errorAccessKeyInvalidPassphrase)
        case .publicKeyMismatch: TerminatorCoreLocalization.text(.errorAccessKeyPublicKeyMismatch)
        case .invalidRSAKeySize: TerminatorCoreLocalization.text(.errorAccessKeyInvalidRSAKeySize)
        case .secureEnclaveUnavailable: TerminatorCoreLocalization.text(.errorAccessKeySecureEnclaveUnavailable)
        case .secureEnclaveKeyIsNotExportable: TerminatorCoreLocalization.text(.errorAccessKeySecureEnclaveKeyIsNotExportable)
        case .authorizationCancelled: TerminatorCoreLocalization.text(.errorAccessKeyAuthorizationCancelled)
        case .passphraseRequired: TerminatorCoreLocalization.text(.errorAccessKeyPassphraseRequired)
        }
    }
}
