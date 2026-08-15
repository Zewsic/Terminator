import Foundation
import Testing
@testable import TerminatorCore

@Suite("Credential and identity domain")
struct CredentialIdentityTests {
    @Test("English localization resources resolve display names, errors, and formats")
    func englishLocalizationResources() {
        #expect(CredentialKind.accessKey.displayName == "Access key")
        #expect(HostValidationError.invalidPort.localizedDescription == "The port must be between 1 and 65535.")

        let entry = HistoryEntry(
            entity: .credential,
            entityID: UUID(),
            operation: .restored,
            beforeSnapshot: nil,
            afterSnapshot: nil
        )
        #expect(entry.title == "Credential restored")
        #expect(
            TerminatorCoreLocalization.text("algorithm.rsa", locale: Locale(identifier: "en_US"), 4096)
                == "RSA 4,096"
        )
    }

    @Test("Identity preserves authentication order and rejects duplicates")
    func identityValidation() throws {
        let first = UUID()
        let second = UUID()
        let identity = try IdentityProfile(
            name: "  Production  ",
            username: " deploy ",
            credentialIDs: [first, second]
        ).validated()
        #expect(identity.name == "Production")
        #expect(identity.username == "deploy")
        #expect(identity.credentialIDs == [first, second])
        let empty = try IdentityProfile(name: "", username: "", authenticationMethods: []).validated()
        #expect(empty.name.isEmpty)
        #expect(empty.username.isEmpty)
        #expect(empty.authenticationMethods.isEmpty)
        #expect(throws: IdentityValidationError.duplicateAuthenticationMethod) {
            try IdentityProfile(name: "Duplicate", username: "root", credentialIDs: [first, first]).validated()
        }
        #expect(throws: IdentityValidationError.multiplePasswords) {
            try IdentityProfile(
                name: "Duplicate password",
                username: "root",
                authenticationMethods: [
                    .password(secretID: SecretID()),
                    .password(secretID: SecretID()),
                ]
            ).validated()
        }
    }

    @Test("Secure Enclave metadata accepts only P-256 without a passphrase")
    func secureEnclaveValidation() {
        let id = SecretID()
        let invalid = CredentialMetadata(
            label: "Enclave",
            kind: .accessKey,
            secretID: id,
            accessKey: AccessKeyMetadata(
                algorithm: .ecdsa(.p384),
                backend: .secureEnclave,
                origin: .generated,
                publicKey: "ecdsa-sha2-nistp384 bW9jaw==",
                fingerprint: "SHA256:mock",
                privateMaterialID: id
            )
        )
        #expect(throws: CredentialValidationError.invalidSecureEnclaveAlgorithm) { try invalid.validated() }
    }

    @Test("Version-one host snapshots migrate to manual authentication")
    func decodesLegacyHost() throws {
        let id = UUID()
        let credentialID = UUID()
        let json: [String: Any] = [
            "id": id.uuidString,
            "displayName": "Legacy",
            "hostname": "legacy.example.com",
            "port": 22,
            "username": "root",
            "credentialID": credentialID.uuidString,
            "tags": [],
            "notes": "",
            "createdAt": 0,
            "updatedAt": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let host = try decoder.decode(HostProfile.self, from: data)
        #expect(host.authentication == .manual(
            username: "root",
            authenticationMethods: [.accessKey(credentialID: credentialID)]
        ))
    }
}
