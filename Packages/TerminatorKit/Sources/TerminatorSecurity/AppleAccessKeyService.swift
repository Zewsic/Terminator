import CBcryptPBKDF
import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TerminatorCore

public actor AppleAccessKeyService: AccessKeyService {
    public init() {}

    public func generateSoftwareKey(_ request: AccessKeyGenerationRequest) throws -> PreparedAccessKey {
        let generated: (privateKey: Data, publicBlob: Data)
        switch request.algorithm {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            let publicBytes = key.publicKey.rawRepresentation
            generated = (
                OpenSSHCodec.encodeEd25519PrivateKey(
                    seed: key.rawRepresentation,
                    publicKey: publicBytes,
                    comment: request.comment
                ),
                OpenSSHCodec.ed25519PublicBlob(publicBytes)
            )
        case .ecdsa(let curve):
            generated = try generateECDSA(curve: curve, comment: request.comment)
        case .rsa(let bitCount):
            guard bitCount == 2_048 || bitCount == 4_096 else {
                throw AccessKeyServiceError.invalidRSAKeySize
            }
            generated = try generateRSA(bitCount: bitCount, comment: request.comment)
        }

        let privateMaterial: Data
        if request.passphrase.isEmpty {
            privateMaterial = generated.privateKey
        } else {
            privateMaterial = try OpenSSHCodec.encryptPEM(generated.privateKey, passphrase: request.passphrase)
        }
        return PreparedAccessKey(
            privateMaterial: privateMaterial,
            algorithm: request.algorithm.algorithm,
            backend: .software,
            publicKey: OpenSSHCodec.publicLine(blob: generated.publicBlob, comment: request.comment),
            fingerprint: OpenSSHCodec.fingerprint(generated.publicBlob),
            isPassphraseProtected: !request.passphrase.isEmpty
        )
    }

    public func importSoftwareKey(_ request: AccessKeyImportRequest) throws -> PreparedAccessKey {
        let trimmed = request.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----")
            || trimmed.contains("Proc-Type: 4,ENCRYPTED") {
            throw AccessKeyServiceError.encryptedLegacyFormatUnsupported
        }
        if !trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----")
            && !trimmed.hasPrefix(ProtectedKeyEnvelope.pemHeader) {
            return try importLegacyPEM(request, trimmed: trimmed)
        }

        let keyData = try OpenSSHCodec.decodePEM(request.privateKey)
        if ProtectedKeyEnvelope.isEnvelope(keyData) {
            let clearPEM = try ProtectedKeyEnvelope.open(keyData, passphrase: request.passphrase)
            guard let clearText = String(data: clearPEM, encoding: .utf8) else {
                throw AccessKeyServiceError.invalidPrivateKey
            }
            let clearContainer = try OpenSSHCodec.decodePEM(clearText)
            return try prepareImported(clearKey: clearContainer, storedMaterial: keyData, request: request, isProtected: true)
        }

        guard OpenSSHCodec.isOpenSSHContainer(keyData) else {
            throw AccessKeyServiceError.unsupportedFormat
        }
        let header = try OpenSSHCodec.inspectContainer(keyData)
        if header.cipherName != "none" {
            guard ["aes256-ctr", "aes256-cbc"].contains(header.cipherName),
                  header.kdfName == "bcrypt" else {
                throw AccessKeyServiceError.unsupportedFormat
            }
            if request.passphrase.isEmpty {
                return try prepareImported(
                    clearKey: keyData,
                    storedMaterial: Data(request.privateKey.utf8),
                    request: request,
                    isProtected: true
                )
            }
            let clearPEM = try OpenSSHCodec.decryptPEM(keyData, passphrase: request.passphrase)
            let clearContainer = try OpenSSHCodec.decodePEM(String(decoding: clearPEM, as: UTF8.self))
            return try prepareImported(
                clearKey: clearContainer,
                storedMaterial: Data(request.privateKey.utf8),
                request: request,
                isProtected: true
            )
        }

        let stored: Data
        let protected: Bool
        if request.passphrase.isEmpty {
            stored = Data(request.privateKey.utf8)
            protected = false
        } else {
            stored = try OpenSSHCodec.encryptPEM(Data(request.privateKey.utf8), passphrase: request.passphrase)
            protected = true
        }
        return try prepareImported(clearKey: keyData, storedMaterial: stored, request: request, isProtected: protected)
    }

    public func generateSecureEnclaveKey(label: String) throws -> PreparedAccessKey {
        guard SecureEnclave.isAvailable else { throw AccessKeyServiceError.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &error
        ) else {
            if let error { throw error.takeRetainedValue() }
            throw AccessKeyServiceError.secureEnclaveUnavailable
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let publicBlob = OpenSSHCodec.ecdsaPublicBlob(curve: .p256, publicKey: key.publicKey.x963Representation)
        return PreparedAccessKey(
            privateMaterial: key.dataRepresentation,
            algorithm: .ecdsa(.p256),
            backend: .secureEnclave,
            publicKey: OpenSSHCodec.publicLine(blob: publicBlob, comment: label),
            fingerprint: OpenSSHCodec.fingerprint(publicBlob),
            isPassphraseProtected: false
        )
    }

    public func exportSoftwareKey(privateMaterial: Data, passphrase: String) throws -> Data {
        if ProtectedKeyEnvelope.isEnvelope(privateMaterial) {
            guard !passphrase.isEmpty else { throw AccessKeyServiceError.passphraseRequired }
            return try ProtectedKeyEnvelope.open(privateMaterial, passphrase: passphrase)
        }
        if let text = String(data: privateMaterial, encoding: .utf8),
           let container = try? OpenSSHCodec.decodePEM(text),
           let info = try? OpenSSHCodec.inspectContainer(container),
           info.cipherName != "none" {
            guard !passphrase.isEmpty else { throw AccessKeyServiceError.passphraseRequired }
            return try OpenSSHCodec.decryptPEM(container, passphrase: passphrase)
        }
        return privateMaterial
    }

    public func decodeSoftwareKey(privateMaterial: Data, passphrase: String) throws -> SSHPrivateKeyMaterial {
        let exported = try exportSoftwareKey(privateMaterial: privateMaterial, passphrase: passphrase)
        let container: Data
        if let text = String(data: exported, encoding: .utf8), text.contains("BEGIN") {
            container = try OpenSSHCodec.decodePEM(text)
        } else {
            container = exported
        }
        return try OpenSSHCodec.privateMaterial(from: container)
    }

    private func prepareImported(
        clearKey: Data,
        storedMaterial: Data,
        request: AccessKeyImportRequest,
        isProtected: Bool
    ) throws -> PreparedAccessKey {
        let inspected = try OpenSSHCodec.inspectContainer(clearKey)
        if !request.suppliedPublicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let supplied = try OpenSSHCodec.publicBlob(fromLine: request.suppliedPublicKey)
            guard supplied == inspected.publicBlob else { throw AccessKeyServiceError.publicKeyMismatch }
        }
        return PreparedAccessKey(
            privateMaterial: storedMaterial,
            algorithm: inspected.algorithm,
            backend: .software,
            publicKey: OpenSSHCodec.publicLine(blob: inspected.publicBlob, comment: ""),
            fingerprint: OpenSSHCodec.fingerprint(inspected.publicBlob),
            isPassphraseProtected: isProtected,
            compatibility: inspected.algorithm.isLegacyCompatibility ? .legacyRSA1024 : .current
        )
    }

    private func importLegacyPEM(_ request: AccessKeyImportRequest, trimmed: String) throws -> PreparedAccessKey {
        let normalized: Data
        if trimmed.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") {
            let values = try DERReader.parseRSAPrivateKey(OpenSSHCodec.decodePEMBody(trimmed, type: "RSA PRIVATE KEY"))
            normalized = try normalizeRSA(values)
        } else if trimmed.hasPrefix("-----BEGIN EC PRIVATE KEY-----") {
            normalized = try normalizeECDSA(trimmed)
        } else if trimmed.hasPrefix("-----BEGIN PRIVATE KEY-----") {
            let der = try OpenSSHCodec.decodePEMBody(trimmed, type: "PRIVATE KEY")
            if let ec = try? normalizeECDSA(trimmed) {
                normalized = ec
            } else {
                let pkcs8 = try DERReader.parsePKCS8(der)
                if pkcs8.algorithmOID == DERReader.rsaEncryptionOID {
                    normalized = try normalizeRSA(DERReader.parseRSAPrivateKey(pkcs8.privateKey))
                } else if pkcs8.algorithmOID == DERReader.ed25519OID {
                    let seed = try DERReader.unwrapOctetStringIfPresent(pkcs8.privateKey)
                    guard seed.count == 32 else { throw AccessKeyServiceError.invalidPrivateKey }
                    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                    normalized = OpenSSHCodec.encodeEd25519PrivateKey(
                        seed: seed,
                        publicKey: key.publicKey.rawRepresentation,
                        comment: ""
                    )
                } else {
                    throw AccessKeyServiceError.unsupportedFormat
                }
            }
        } else {
            throw AccessKeyServiceError.unsupportedFormat
        }

        let clearContainer = try OpenSSHCodec.decodePEM(String(decoding: normalized, as: UTF8.self))
        let stored = request.passphrase.isEmpty
            ? normalized
            : try OpenSSHCodec.encryptPEM(normalized, passphrase: request.passphrase)
        return try prepareImported(
            clearKey: clearContainer,
            storedMaterial: stored,
            request: request,
            isProtected: !request.passphrase.isEmpty
        )
    }

    private func normalizeRSA(_ values: RSAPrivateValues) throws -> Data {
        let bitCount = OpenSSHCodec.significantBitCount(values.n)
        guard bitCount == 1_024 || bitCount >= 2_048 else {
            throw AccessKeyServiceError.invalidRSAKeySize
        }
        let publicBlob = OpenSSHCodec.rsaPublicBlob(exponent: values.e, modulus: values.n)
        return OpenSSHCodec.encodeRSAPrivateKey(values, publicBlob: publicBlob, comment: "")
    }

    private func normalizeECDSA(_ pem: String) throws -> Data {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return OpenSSHCodec.encodeECDSAPrivateKey(
                curve: .p256,
                scalar: key.rawRepresentation,
                publicKey: key.publicKey.x963Representation,
                comment: ""
            )
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: pem) {
            return OpenSSHCodec.encodeECDSAPrivateKey(
                curve: .p384,
                scalar: key.rawRepresentation,
                publicKey: key.publicKey.x963Representation,
                comment: ""
            )
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: pem) {
            return OpenSSHCodec.encodeECDSAPrivateKey(
                curve: .p521,
                scalar: key.rawRepresentation,
                publicKey: key.publicKey.x963Representation,
                comment: ""
            )
        }
        throw AccessKeyServiceError.invalidPrivateKey
    }

    private func generateECDSA(curve: ECDSACurve, comment: String) throws -> (Data, Data) {
        switch curve {
        case .p256:
            let key = P256.Signing.PrivateKey()
            return (
                OpenSSHCodec.encodeECDSAPrivateKey(curve: curve, scalar: key.rawRepresentation, publicKey: key.publicKey.x963Representation, comment: comment),
                OpenSSHCodec.ecdsaPublicBlob(curve: curve, publicKey: key.publicKey.x963Representation)
            )
        case .p384:
            let key = P384.Signing.PrivateKey()
            return (
                OpenSSHCodec.encodeECDSAPrivateKey(curve: curve, scalar: key.rawRepresentation, publicKey: key.publicKey.x963Representation, comment: comment),
                OpenSSHCodec.ecdsaPublicBlob(curve: curve, publicKey: key.publicKey.x963Representation)
            )
        case .p521:
            let key = P521.Signing.PrivateKey()
            return (
                OpenSSHCodec.encodeECDSAPrivateKey(curve: curve, scalar: key.rawRepresentation, publicKey: key.publicKey.x963Representation, comment: comment),
                OpenSSHCodec.ecdsaPublicBlob(curve: curve, publicKey: key.publicKey.x963Representation)
            )
        }
    }

    private func generateRSA(bitCount: Int, comment: String) throws -> (Data, Data) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bitCount,
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw AccessKeyServiceError.invalidPrivateKey
        }
        guard let representation = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            if let error { throw error.takeRetainedValue() }
            throw AccessKeyServiceError.invalidPrivateKey
        }
        let values = try DERReader.parseRSAPrivateKey(representation)
        let publicBlob = OpenSSHCodec.rsaPublicBlob(exponent: values.e, modulus: values.n)
        return (OpenSSHCodec.encodeRSAPrivateKey(values, publicBlob: publicBlob, comment: comment), publicBlob)
    }
}
