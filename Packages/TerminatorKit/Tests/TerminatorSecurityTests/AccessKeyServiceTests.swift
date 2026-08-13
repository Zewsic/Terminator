import CryptoKit
import Foundation
import Security
import Testing
import TerminatorCore
import TerminatorSecurity
import TerminatorTestSupport

@Suite("Access key security", .serialized)
struct AccessKeyServiceTests {
    @Test("Generated Ed25519 key round-trips through OpenSSH import")
    func ed25519RoundTrip() async throws {
        let service = AppleAccessKeyService()
        let generated = try await service.generateSoftwareKey(.init(algorithm: .ed25519, comment: "test@terminator"))
        let pem = try #require(String(data: generated.privateMaterial, encoding: .utf8))
        #expect(pem.contains("BEGIN OPENSSH PRIVATE KEY"))
        #expect(generated.publicKey.hasPrefix("ssh-ed25519 "))

        let imported = try await service.importSoftwareKey(.init(privateKey: pem, suppliedPublicKey: generated.publicKey))
        #expect(imported.algorithm == .ed25519)
        #expect(imported.fingerprint == generated.fingerprint)
    }

    @Test("Imports an ssh-keygen bcrypt/AES-CTR vector")
    func importsExternalEncryptedVector() async throws {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDF6eUEIT
        Rit2ZxGfrL6o3TAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIC9KMVIVDZ8paHvV
        OJf/Pb5wUWXyGaZy2T8nJu2TTfQuAAAAoPKJWQoTIWwaV5rsstFfYafED7R1oX5iGhSg3b
        6wcGHZz5LXgFJVCsy3pcx13hSb3TAUIqQkybxFxN6saRgr/vPD4o3rLw99b7FuTNt3FT4D
        ylnC7qjXFXTYkRCGv0LbGuxBbPbb7muY+ccvDHDXychUigstZdRbAG/1UOpnb4kql0L/Wo
        HRDbAweCE5OQ70RxNOHbuN8LrEyPJ2hpZ+Gis=
        -----END OPENSSH PRIVATE KEY-----
        """
        let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC9KMVIVDZ8paHvVOJf/Pb5wUWXyGaZy2T8nJu2TTfQu terminator-vector"
        let imported = try await AppleAccessKeyService().importSoftwareKey(.init(
            privateKey: pem,
            suppliedPublicKey: publicKey,
            passphrase: "vector-passphrase"
        ))
        #expect(imported.algorithm == .ed25519)
        #expect(imported.isPassphraseProtected)
        #expect(imported.publicKey.hasPrefix("ssh-ed25519 "))

        await #expect(throws: AccessKeyServiceError.invalidPassphrase) {
            try await AppleAccessKeyService().importSoftwareKey(.init(privateKey: pem, passphrase: "wrong"))
        }
    }

    @Test("Passphrase-protected generated keys require the correct passphrase")
    func protectedKey() async throws {
        let service = AppleAccessKeyService()
        let generated = try await service.generateSoftwareKey(.init(
            algorithm: .ecdsa(.p256),
            passphrase: "correct horse battery staple"
        ))
        #expect(generated.isPassphraseProtected)
        #expect(String(data: generated.privateMaterial, encoding: .utf8)?.contains("BEGIN OPENSSH PRIVATE KEY") == true)

        let reimported = try await service.importSoftwareKey(.init(
            privateKey: String(decoding: generated.privateMaterial, as: UTF8.self),
            passphrase: "correct horse battery staple"
        ))
        #expect(reimported.algorithm == .ecdsa(.p256))

        await #expect(throws: AccessKeyServiceError.invalidPassphrase) {
            try await service.exportSoftwareKey(privateMaterial: generated.privateMaterial, passphrase: "wrong")
        }
        let exported = try await service.exportSoftwareKey(
            privateMaterial: generated.privateMaterial,
            passphrase: "correct horse battery staple"
        )
        #expect(String(data: exported, encoding: .utf8)?.contains("BEGIN OPENSSH PRIVATE KEY") == true)
    }

    @Test("ECDSA curves and RSA-2048 expose correct metadata")
    func generatedAlgorithms() async throws {
        let service = AppleAccessKeyService()
        for curve in ECDSACurve.allCases {
            let key = try await service.generateSoftwareKey(.init(algorithm: .ecdsa(curve)))
            #expect(key.algorithm == .ecdsa(curve))
            #expect(key.publicKey.hasPrefix("ecdsa-sha2-\(curve.sshName) "))
        }
        let rsa = try await service.generateSoftwareKey(.init(algorithm: .rsa(bitCount: 2_048)))
        #expect(rsa.algorithm == .rsa(bitCount: 2_048))
        #expect(rsa.publicKey.hasPrefix("ssh-rsa "))
    }

    @Test("Unencrypted EC PEM is normalized to OpenSSH")
    func importsECPem() async throws {
        let source = P384.Signing.PrivateKey()
        let service = AppleAccessKeyService()
        let imported = try await service.importSoftwareKey(.init(privateKey: source.pemRepresentation))

        #expect(imported.algorithm == .ecdsa(.p384))
        #expect(imported.publicKey.hasPrefix("ecdsa-sha2-nistp384 "))
        #expect(String(data: imported.privateMaterial, encoding: .utf8)?.contains("BEGIN OPENSSH PRIVATE KEY") == true)
    }

    @Test("Unencrypted RSA PKCS#1 is normalized to OpenSSH")
    func importsRSAPKCS1() async throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let der = try #require(SecKeyCopyExternalRepresentation(key, &error) as Data?)
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n\(body)-----END RSA PRIVATE KEY-----\n"

        let imported = try await AppleAccessKeyService().importSoftwareKey(.init(privateKey: pem))
        #expect(imported.algorithm == .rsa(bitCount: 2_048))
        #expect(imported.publicKey.hasPrefix("ssh-rsa "))
    }

    @Test("Resolver preserves order and asks once for an unsaved passphrase")
    func resolverOrder() async throws {
        let passwordID = SecretID()
        let keyMaterialID = SecretID()
        let password = CredentialMetadata(label: "Password", kind: .password, secretID: passwordID)
        let key = CredentialMetadata(
            label: "Key",
            kind: .accessKey,
            secretID: keyMaterialID,
            accessKey: AccessKeyMetadata(
                algorithm: .ed25519,
                backend: .software,
                origin: .generated,
                publicKey: "ssh-ed25519 bW9jaw==",
                fingerprint: "SHA256:mock",
                privateMaterialID: keyMaterialID,
                passphraseProtection: .promptEveryConnection
            )
        )
        let identity = IdentityProfile(
            name: "Production",
            username: "deploy",
            authenticationMethods: [
                .accessKey(credentialID: key.id),
                .password(secretID: passwordID),
            ]
        )
        let catalog = InMemoryTerminatorStore(credentials: [password, key], identities: [identity])
        let secrets = InMemorySecretStore()
        try await secrets.store(Data("password".utf8), for: passwordID)
        try await secrets.store(Data("private".utf8), for: keyMaterialID)
        let prompt = CountingPrompt()
        let resolver = AuthenticationResolver(credentialRepository: catalog, identityRepository: catalog, secretStore: secrets)

        let result = try await resolver.resolve(
            host: HostProfile(displayName: "Prod", hostname: "prod.example.com", authentication: .identity(identity.id)),
            prompting: prompt
        )
        #expect(result.username == "deploy")
        #expect(result.methods.count == 2)
        #expect(await prompt.count == 1)
        if case .softwareKey(_, _, let passphrase) = result.methods[0] { #expect(passphrase == "phrase") }
        else { Issue.record("Expected software key first") }
        if case .password = result.methods[1] {} else { Issue.record("Expected password second") }
    }
}

private actor CountingPrompt: CredentialPrompting {
    private(set) var count = 0
    func requestPassphrase(for credential: CredentialMetadata) -> String {
        count += 1
        return "phrase"
    }
}
