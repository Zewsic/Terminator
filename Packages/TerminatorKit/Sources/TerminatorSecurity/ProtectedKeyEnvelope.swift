import CBcryptPBKDF
import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TerminatorCore

struct ProtectedKeyEnvelope: Codable {
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
