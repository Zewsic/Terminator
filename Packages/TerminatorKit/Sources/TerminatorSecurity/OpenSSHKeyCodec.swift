import CBcryptPBKDF
import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TerminatorCore

struct OpenSSHContainerInfo {
    var cipherName: String
    var kdfName: String
    var kdfOptions: Data
    var publicBlob: Data
    var privateBlock: Data
    var algorithm: SSHKeyAlgorithm
}

enum OpenSSHCodec {
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
