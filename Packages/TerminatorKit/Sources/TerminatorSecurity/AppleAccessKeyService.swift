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

private struct OpenSSHContainerInfo {
    var cipherName: String
    var kdfName: String
    var kdfOptions: Data
    var publicBlob: Data
    var privateBlock: Data
    var algorithm: SSHKeyAlgorithm
}

private enum OpenSSHCodec {
    private static let magic = Data("openssh-key-v1\0".utf8)

    static func isOpenSSHContainer(_ data: Data) -> Bool { data.starts(with: magic) }

    static func decodePEM(_ value: String) throws -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
            let body = trimmed
                .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
                .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
                .filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: body) else { throw AccessKeyServiceError.invalidPrivateKey }
            return data
        }
        if trimmed.hasPrefix(ProtectedKeyEnvelope.pemHeader) {
            let body = trimmed
                .replacingOccurrences(of: ProtectedKeyEnvelope.pemHeader, with: "")
                .replacingOccurrences(of: ProtectedKeyEnvelope.pemFooter, with: "")
                .filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: body) else { throw AccessKeyServiceError.invalidPrivateKey }
            return data
        }
        throw AccessKeyServiceError.unsupportedFormat
    }

    static func decodePEMBody(_ value: String, type: String) throws -> Data {
        let header = "-----BEGIN \(type)-----"
        let footer = "-----END \(type)-----"
        guard value.hasPrefix(header), value.contains(footer) else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        let body = value
            .replacingOccurrences(of: header, with: "")
            .replacingOccurrences(of: footer, with: "")
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: body) else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        return data
    }

    static func inspectContainer(_ data: Data) throws -> OpenSSHContainerInfo {
        guard data.starts(with: magic) else { throw AccessKeyServiceError.invalidPrivateKey }
        var reader = SSHReader(Data(data.dropFirst(magic.count)))
        let cipherName = try reader.readStringText()
        let kdfName = try reader.readStringText()
        let kdfOptions = try reader.readString()
        guard try reader.readUInt32() == 1 else { throw AccessKeyServiceError.invalidPrivateKey }
        let publicBlob = try reader.readString()
        let algorithm = try inspectPublicBlob(publicBlob)
        let privateBlock = try reader.readString()
        if cipherName == "none" {
            var privateReader = SSHReader(privateBlock)
            guard try privateReader.readUInt32() == privateReader.readUInt32() else {
                throw AccessKeyServiceError.invalidPrivateKey
            }
        }
        return OpenSSHContainerInfo(
            cipherName: cipherName,
            kdfName: kdfName,
            kdfOptions: kdfOptions,
            publicBlob: publicBlob,
            privateBlock: privateBlock,
            algorithm: algorithm
        )
    }

    static func privateMaterial(from data: Data) throws -> SSHPrivateKeyMaterial {
        let info = try inspectContainer(data)
        guard info.cipherName == "none" else { throw AccessKeyServiceError.passphraseRequired }
        var reader = SSHReader(info.privateBlock)
        guard try reader.readUInt32() == reader.readUInt32() else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        let name = try reader.readStringText()
        switch name {
        case "ssh-ed25519":
            _ = try reader.readString()
            let combined = try reader.readString()
            guard combined.count >= 32 else { throw AccessKeyServiceError.invalidPrivateKey }
            return .ed25519(seed: Data(combined.prefix(32)))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curveName = try reader.readStringText()
            _ = try reader.readString()
            let scalar = stripMPIntPadding(try reader.readString())
            let curve: ECDSACurve
            switch curveName {
            case "nistp256": curve = .p256
            case "nistp384": curve = .p384
            case "nistp521": curve = .p521
            default: throw AccessKeyServiceError.unsupportedFormat
            }
            return .ecdsa(curve: curve, scalar: scalar)
        case "ssh-rsa":
            let modulus = stripMPIntPadding(try reader.readString())
            let exponent = stripMPIntPadding(try reader.readString())
            let privateExponent = stripMPIntPadding(try reader.readString())
            let iqmp = stripMPIntPadding(try reader.readString())
            let p = stripMPIntPadding(try reader.readString())
            let q = stripMPIntPadding(try reader.readString())
            return .rsa(
                modulus: modulus, exponent: exponent, privateExponent: privateExponent,
                p: p, q: q, iqmp: iqmp
            )
        default:
            throw AccessKeyServiceError.unsupportedFormat
        }
    }

    private static func stripMPIntPadding(_ data: Data) -> Data {
        guard data.first == 0, data.count > 1 else { return data }
        return Data(data.dropFirst())
    }

    static func encryptPEM(_ pemData: Data, passphrase: String, rounds: UInt32 = 24) throws -> Data {
        guard !passphrase.isEmpty, let text = String(data: pemData, encoding: .utf8) else {
            throw AccessKeyServiceError.invalidPassphrase
        }
        let container = try decodePEM(text)
        let info = try inspectContainer(container)
        guard info.cipherName == "none" else { return pemData }

        let salt = randomData(count: 16)
        let keyAndIV = try BCryptPBKDF.derive(passphrase: passphrase, salt: salt, rounds: rounds, count: 48)
        let clearBlock = try repad(info.privateBlock, blockSize: 16)
        let encrypted = try AESCTR.crypt(clearBlock, key: Data(keyAndIV.prefix(32)), iv: Data(keyAndIV.suffix(16)))

        var options = SSHWriter()
        options.writeString(salt)
        options.writeUInt32(rounds)
        var writer = SSHWriter(data: magic)
        writer.writeString("aes256-ctr")
        writer.writeString("bcrypt")
        writer.writeString(options.data)
        writer.writeUInt32(1)
        writer.writeString(info.publicBlob)
        writer.writeString(encrypted)
        return pem(writer.data)
    }

    static func decryptPEM(_ container: Data, passphrase: String) throws -> Data {
        let info = try inspectContainer(container)
        guard ["aes256-ctr", "aes256-cbc"].contains(info.cipherName),
              info.kdfName == "bcrypt", !passphrase.isEmpty else {
            throw AccessKeyServiceError.unsupportedFormat
        }
        var options = SSHReader(info.kdfOptions)
        let salt = try options.readString()
        let rounds = try options.readUInt32()
        let keyAndIV = try BCryptPBKDF.derive(passphrase: passphrase, salt: salt, rounds: rounds, count: 48)
        let key = Data(keyAndIV.prefix(32))
        let iv = Data(keyAndIV.suffix(16))
        let clear: Data
        switch info.cipherName {
        case "aes256-ctr":
            clear = try AESCTR.crypt(info.privateBlock, key: key, iv: iv)
        case "aes256-cbc":
            clear = try AESCBC.decrypt(info.privateBlock, key: key, iv: iv)
        default:
            throw AccessKeyServiceError.unsupportedFormat
        }
        do {
            var privateReader = SSHReader(clear)
            guard try privateReader.readUInt32() == privateReader.readUInt32() else {
                throw AccessKeyServiceError.invalidPassphrase
            }
        } catch {
            throw AccessKeyServiceError.invalidPassphrase
        }

        let block = try repad(clear, blockSize: 8)
        return wrapPrivate(publicBlob: info.publicBlob, block: block)
    }

    private static func repad(_ data: Data, blockSize: Int) throws -> Data {
        guard let last = data.last else { throw AccessKeyServiceError.invalidPrivateKey }
        let paddingCount = Int(last)
        guard paddingCount > 0, paddingCount <= 16, data.count >= paddingCount else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        let padding = data.suffix(paddingCount)
        guard padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) }) else {
            throw AccessKeyServiceError.invalidPassphrase
        }
        var result = Data(data.dropLast(paddingCount))
        var byte: UInt8 = 1
        repeat {
            result.append(byte)
            byte &+= 1
        } while result.count % blockSize != 0
        return result
    }

    private static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { return Data() }
        return Data(bytes)
    }

    static func inspectPublicBlob(_ data: Data) throws -> SSHKeyAlgorithm {
        var reader = SSHReader(data)
        let name = try reader.readStringText()
        switch name {
        case "ssh-ed25519": return .ed25519
        case "ecdsa-sha2-nistp256": return .ecdsa(.p256)
        case "ecdsa-sha2-nistp384": return .ecdsa(.p384)
        case "ecdsa-sha2-nistp521": return .ecdsa(.p521)
        case "ssh-rsa":
            _ = try reader.readString()
            let modulus = try reader.readString()
            return .rsa(bitCount: significantBitCount(modulus))
        default: throw AccessKeyServiceError.unsupportedFormat
        }
    }

    static func publicBlob(fromLine line: String) throws -> Data {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let data = Data(base64Encoded: String(fields[1])) else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        _ = try inspectPublicBlob(data)
        return data
    }

    static func publicLine(blob: Data, comment: String) -> String {
        var reader = SSHReader(blob)
        let algorithm = (try? reader.readStringText()) ?? "unknown"
        let suffix = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(algorithm) \(blob.base64EncodedString())" + (suffix.isEmpty ? "" : " \(suffix)")
    }

    static func fingerprint(_ blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func ed25519PublicBlob(_ publicKey: Data) -> Data {
        var writer = SSHWriter()
        writer.writeString("ssh-ed25519")
        writer.writeString(publicKey)
        return writer.data
    }

    static func ecdsaPublicBlob(curve: ECDSACurve, publicKey: Data) -> Data {
        var writer = SSHWriter()
        writer.writeString("ecdsa-sha2-\(curve.sshName)")
        writer.writeString(curve.sshName)
        writer.writeString(publicKey)
        return writer.data
    }

    static func rsaPublicBlob(exponent: Data, modulus: Data) -> Data {
        var writer = SSHWriter()
        writer.writeString("ssh-rsa")
        writer.writeMPInt(exponent)
        writer.writeMPInt(modulus)
        return writer.data
    }

    static func encodeEd25519PrivateKey(seed: Data, publicKey: Data, comment: String) -> Data {
        var privateWriter = SSHWriter()
        writeChecks(to: &privateWriter)
        privateWriter.writeString("ssh-ed25519")
        privateWriter.writeString(publicKey)
        privateWriter.writeString(seed + publicKey)
        privateWriter.writeString(comment)
        return wrapPrivate(publicBlob: ed25519PublicBlob(publicKey), block: privateWriter.padded(blockSize: 8))
    }

    static func encodeECDSAPrivateKey(curve: ECDSACurve, scalar: Data, publicKey: Data, comment: String) -> Data {
        var privateWriter = SSHWriter()
        writeChecks(to: &privateWriter)
        privateWriter.writeString("ecdsa-sha2-\(curve.sshName)")
        privateWriter.writeString(curve.sshName)
        privateWriter.writeString(publicKey)
        privateWriter.writeMPInt(scalar)
        privateWriter.writeString(comment)
        return wrapPrivate(publicBlob: ecdsaPublicBlob(curve: curve, publicKey: publicKey), block: privateWriter.padded(blockSize: 8))
    }

    static func encodeRSAPrivateKey(_ key: RSAPrivateValues, publicBlob: Data, comment: String) -> Data {
        var privateWriter = SSHWriter()
        writeChecks(to: &privateWriter)
        privateWriter.writeString("ssh-rsa")
        privateWriter.writeMPInt(key.n)
        privateWriter.writeMPInt(key.e)
        privateWriter.writeMPInt(key.d)
        privateWriter.writeMPInt(key.iqmp)
        privateWriter.writeMPInt(key.p)
        privateWriter.writeMPInt(key.q)
        privateWriter.writeString(comment)
        return wrapPrivate(publicBlob: publicBlob, block: privateWriter.padded(blockSize: 8))
    }

    private static func wrapPrivate(publicBlob: Data, block: Data) -> Data {
        var writer = SSHWriter(data: magic)
        writer.writeString("none")
        writer.writeString("none")
        writer.writeString(Data())
        writer.writeUInt32(1)
        writer.writeString(publicBlob)
        writer.writeString(block)
        return pem(writer.data)
    }

    private static func pem(_ binary: Data) -> Data {
        let base64 = binary.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)-----END OPENSSH PRIVATE KEY-----\n".utf8)
    }

    private static func writeChecks(to writer: inout SSHWriter) {
        var random = UInt32.random(in: UInt32.min...UInt32.max)
        writer.writeUInt32(random)
        writer.writeUInt32(random)
        random = 0
    }

    static func significantBitCount(_ data: Data) -> Int {
        let bytes = Array(data.drop(while: { $0 == 0 }))
        guard let first = bytes.first else { return 0 }
        return (bytes.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }
}

private struct SSHWriter {
    var data = Data()
    init(data: Data = Data()) { self.data = data }

    mutating func writeUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    mutating func writeString(_ value: String) { writeString(Data(value.utf8)) }
    mutating func writeString(_ value: Data) {
        writeUInt32(UInt32(value.count))
        data.append(value)
    }
    mutating func writeMPInt(_ raw: Data) {
        var value = Data(raw.drop(while: { $0 == 0 }))
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        writeString(value)
    }
    func padded(blockSize: Int) -> Data {
        var result = data
        var byte: UInt8 = 1
        repeat {
            result.append(byte)
            byte &+= 1
        } while result.count % blockSize != 0
        return result
    }
}

private struct SSHReader {
    var data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw AccessKeyServiceError.invalidPrivateKey }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }
    mutating func readString() throws -> Data {
        let count = Int(try readUInt32())
        guard count >= 0, offset + count <= data.count else { throw AccessKeyServiceError.invalidPrivateKey }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }
    mutating func readStringText() throws -> String {
        guard let value = String(data: try readString(), encoding: .utf8) else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        return value
    }
}

private enum BCryptPBKDF {
    static func derive(passphrase: String, salt: Data, rounds: UInt32, count: Int) throws -> Data {
        var output = [UInt8](repeating: 0, count: count)
        let password = Array(passphrase.utf8)
        let result = password.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                bcrypt_pbkdf(
                    passwordBuffer.baseAddress,
                    passwordBuffer.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    &output,
                    output.count,
                    rounds
                )
            }
        }
        guard result == 0 else { throw AccessKeyServiceError.invalidPassphrase }
        return Data(output)
    }
}

private enum AESCTR {
    static func crypt(_ input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBuffer.baseAddress,
                    keyBuffer.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: input.count)
        let outputCount = output.count
        var moved = 0
        let updateStatus = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                CCCryptorUpdate(
                    cryptor,
                    inputBuffer.baseAddress,
                    input.count,
                    outputBuffer.baseAddress,
                    outputCount,
                    &moved
                )
            }
        }
        guard updateStatus == kCCSuccess, moved == input.count else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        return output
    }
}

private enum AESCBC {
    static func decrypt(_ input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256,
              iv.count == kCCBlockSizeAES128,
              input.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        var output = Data(count: input.count)
        let outputCount = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBuffer.baseAddress,
                            key.count,
                            ivBuffer.baseAddress,
                            inputBuffer.baseAddress,
                            input.count,
                            outputBuffer.baseAddress,
                            outputCount,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved == input.count else {
            throw AccessKeyServiceError.invalidPrivateKey
        }
        return output
    }
}

private struct RSAPrivateValues {
    var n: Data
    var e: Data
    var d: Data
    var p: Data
    var q: Data
    var iqmp: Data
}

private enum DERReader {
    static let rsaEncryptionOID = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
    static let ed25519OID = Data([0x2b, 0x65, 0x70])

    struct PKCS8Values {
        var algorithmOID: Data
        var privateKey: Data
    }

    static func parseRSAPrivateKey(_ data: Data) throws -> RSAPrivateValues {
        var reader = Cursor(data)
        let sequence = try reader.read(tag: 0x30)
        var values = Cursor(sequence)
        _ = try values.read(tag: 0x02)
        let n = try values.read(tag: 0x02)
        let e = try values.read(tag: 0x02)
        let d = try values.read(tag: 0x02)
        let p = try values.read(tag: 0x02)
        let q = try values.read(tag: 0x02)
        _ = try values.read(tag: 0x02)
        _ = try values.read(tag: 0x02)
        let iqmp = try values.read(tag: 0x02)
        return RSAPrivateValues(n: n, e: e, d: d, p: p, q: q, iqmp: iqmp)
    }

    static func parsePKCS8(_ data: Data) throws -> PKCS8Values {
        var reader = Cursor(data)
        let sequence = try reader.read(tag: 0x30)
        var values = Cursor(sequence)
        _ = try values.read(tag: 0x02)
        let algorithm = try values.read(tag: 0x30)
        var algorithmValues = Cursor(algorithm)
        let oid = try algorithmValues.read(tag: 0x06)
        let privateKey = try values.read(tag: 0x04)
        return PKCS8Values(algorithmOID: oid, privateKey: privateKey)
    }

    static func unwrapOctetStringIfPresent(_ data: Data) throws -> Data {
        guard data.first == 0x04 else { return data }
        var reader = Cursor(data)
        return try reader.read(tag: 0x04)
    }

    private struct Cursor {
        var data: Data
        var offset = 0
        init(_ data: Data) { self.data = data }

        mutating func read(tag: UInt8) throws -> Data {
            guard offset < data.count, data[offset] == tag else { throw AccessKeyServiceError.invalidPrivateKey }
            offset += 1
            let length = try readLength()
            guard offset + length <= data.count else { throw AccessKeyServiceError.invalidPrivateKey }
            defer { offset += length }
            return Data(data[offset..<(offset + length)])
        }

        mutating func readLength() throws -> Int {
            guard offset < data.count else { throw AccessKeyServiceError.invalidPrivateKey }
            let first = data[offset]
            offset += 1
            if first & 0x80 == 0 { return Int(first) }
            let byteCount = Int(first & 0x7f)
            guard (1...4).contains(byteCount), offset + byteCount <= data.count else {
                throw AccessKeyServiceError.invalidPrivateKey
            }
            var result = 0
            for _ in 0..<byteCount {
                result = (result << 8) | Int(data[offset])
                offset += 1
            }
            return result
        }
    }
}

private struct ProtectedKeyEnvelope: Codable {
    static let magic = Data("TERMINATOR-SSH-KEY-V1\0".utf8)
    static let pemHeader = "-----BEGIN TERMINATOR PROTECTED SSH KEY-----"
    static let pemFooter = "-----END TERMINATOR PROTECTED SSH KEY-----"
    static let iterations = 210_000

    var salt: Data
    var nonce: Data
    var ciphertext: Data
    var tag: Data

    static func isEnvelope(_ data: Data) -> Bool { data.starts(with: magic) }

    static func seal(_ cleartext: Data, passphrase: String) throws -> Data {
        let salt = randomData(count: 16)
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let nonce = try AES.GCM.Nonce(data: randomData(count: 12))
        let box = try AES.GCM.seal(cleartext, using: key, nonce: nonce)
        let envelope = ProtectedKeyEnvelope(
            salt: salt,
            nonce: Data(nonce),
            ciphertext: box.ciphertext,
            tag: box.tag
        )
        return magic + (try JSONEncoder().encode(envelope))
    }

    static func open(_ data: Data, passphrase: String) throws -> Data {
        guard isEnvelope(data), !passphrase.isEmpty else { throw AccessKeyServiceError.invalidPassphrase }
        let envelope = try JSONDecoder().decode(ProtectedKeyEnvelope.self, from: Data(data.dropFirst(magic.count)))
        let key = deriveKey(passphrase: passphrase, salt: envelope.salt, iterations: iterations)
        do {
            let nonce = try AES.GCM.Nonce(data: envelope.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext, tag: envelope.tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw AccessKeyServiceError.invalidPassphrase
        }
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        let password = SymmetricKey(data: Data(passphrase.utf8))
        var block = salt
        var counter = UInt32(1).bigEndian
        withUnsafeBytes(of: &counter) { block.append(contentsOf: $0) }
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: password))
        var output = u
        if iterations > 1 {
            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: password))
                for index in output.indices { output[index] ^= u[index] }
            }
        }
        return SymmetricKey(data: output)
    }

    private static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        return Data(bytes)
    }
}
