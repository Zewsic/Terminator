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
        var username: String
        let authenticationMethods: [AuthenticationMethod]
        switch host.authentication {
        case .identity(let identityID):
            guard let identity = try await identityRepository.identity(id: identityID), !identity.isDeleted else {
                throw HostValidationError.referencedIdentityUnavailable
            }
            let storedUsername = identity.username.trimmingCharacters(in: .whitespacesAndNewlines)
            username = storedUsername
            authenticationMethods = identity.authenticationMethods
        case .manual(let value, let methods):
            let storedUsername = value.trimmingCharacters(in: .whitespacesAndNewlines)
            username = storedUsername
            authenticationMethods = methods
        }

        if username.isEmpty, !authenticationMethods.isEmpty {
            username = try await prompting.requestUsername(for: host)
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
        if methods.isEmpty {
            let availableAccessKeys = try await credentialRepository.listCredentials(includeDeleted: false).filter {
                $0.kind == .accessKey && $0.isSecretAvailable
            }
            let availableIdentities = try await identityRepository.listIdentities(includeDeleted: false).filter {
                !$0.isDeleted && !$0.authenticationMethods.isEmpty
            }
            let choice = try await prompting.requestAuthentication(
                for: host,
                username: username,
                availableAccessKeys: availableAccessKeys,
                availableIdentities: availableIdentities
            )
            username = choice.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if let identityID = choice.identityID {
                guard let identity = availableIdentities.first(where: { $0.id == identityID }) else {
                    throw HostValidationError.referencedIdentityUnavailable
                }
                let identityUsername = identity.username.trimmingCharacters(in: .whitespacesAndNewlines)
                if !identityUsername.isEmpty { username = identityUsername }
                for method in identity.authenticationMethods {
                    switch method {
                    case .password(let secretID):
                        methods.append(.password(
                            credentialID: identity.id,
                            value: try await secretStore.read(id: secretID)
                        ))
                    case .accessKey(let credentialID):
                        try await appendCredential(id: credentialID, to: &methods, prompting: prompting)
                    }
                }
            } else {
                if let password = choice.password, !password.isEmpty {
                    methods.append(.password(credentialID: host.id, value: Data(password.utf8)))
                }
                if let credentialID = choice.credentialID {
                    try await appendCredential(id: credentialID, to: &methods, prompting: prompting)
                }
            }
            guard !username.isEmpty, !methods.isEmpty else { throw CancellationError() }
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
