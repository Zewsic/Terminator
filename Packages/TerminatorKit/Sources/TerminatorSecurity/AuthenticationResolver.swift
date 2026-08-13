import Foundation
import LocalAuthentication
import TerminatorCore

public actor AuthenticationResolver: AuthenticationResolving {
    private let credentialRepository: any CredentialRepository
    private let identityRepository: any IdentityRepository
    private let secretStore: any SecretStore

    public init(
        credentialRepository: any CredentialRepository,
        identityRepository: any IdentityRepository,
        secretStore: any SecretStore
    ) {
        self.credentialRepository = credentialRepository
        self.identityRepository = identityRepository
        self.secretStore = secretStore
    }

    public func resolve(host: HostProfile, prompting: any CredentialPrompting) async throws -> ResolvedSSHIdentity {
        let username: String
        let authenticationMethods: [AuthenticationMethod]
        switch host.authentication {
        case .identity(let identityID):
            guard let identity = try await identityRepository.identity(id: identityID), !identity.isDeleted else {
                throw HostValidationError.referencedIdentityUnavailable
            }
            username = identity.username
            authenticationMethods = identity.authenticationMethods
        case .manual(let value, let methods):
            username = value
            authenticationMethods = methods
        }

        var methods: [ResolvedAuthenticationMethod] = []
        for method in authenticationMethods {
            switch method {
            case .password(let secretID):
                methods.append(.password(
                    credentialID: host.id,
                    value: try await secretStore.read(id: secretID)
                ))
            case .accessKey(let credentialID):
                try await appendCredential(id: credentialID, to: &methods, prompting: prompting)
            }
        }
        return ResolvedSSHIdentity(username: username, methods: methods)
    }

    private func appendCredential(
        id: UUID,
        to methods: inout [ResolvedAuthenticationMethod],
        prompting: any CredentialPrompting
    ) async throws {
        guard let credential = try await credentialRepository.credential(id: id),
              !credential.isDeleted,
              credential.isSecretAvailable else {
            throw HostValidationError.referencedCredentialUnavailable
        }
        switch credential.kind {
            case .password:
                methods.append(.password(credentialID: id, value: try await secretStore.read(id: credential.secretID)))
            case .legacyPassphrase:
                return
            case .accessKey:
                guard let key = credential.accessKey else { throw CredentialValidationError.missingAccessKeyMetadata }
                let privateMaterial = try await secretStore.read(id: key.privateMaterialID)
                if key.backend == .secureEnclave {
                    methods.append(.secureEnclaveKey(credentialID: id, keyReference: privateMaterial))
                } else {
                    let passphrase: String?
                    switch key.passphraseProtection {
                    case .none:
                        passphrase = nil
                    case .saved(let secretID):
                        let data = try await secretStore.read(id: secretID)
                        guard let value = String(data: data, encoding: .utf8) else {
                            throw AccessKeyServiceError.invalidPassphrase
                        }
                        passphrase = value
                    case .promptEveryConnection:
                        passphrase = try await prompting.requestPassphrase(for: credential)
                    }
                    methods.append(.softwareKey(credentialID: id, privateMaterial: privateMaterial, passphrase: passphrase))
                }
            }
    }
}

public actor LocalAuthenticationAuthorizer: UserPresenceAuthorizer {
    public init() {}

    public func authorize(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? AccessKeyServiceError.authorizationCancelled
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw AccessKeyServiceError.authorizationCancelled
            }
        } catch {
            throw error
        }
    }
}
