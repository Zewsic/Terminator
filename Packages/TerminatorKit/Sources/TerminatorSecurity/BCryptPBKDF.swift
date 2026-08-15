import CBcryptPBKDF
import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TerminatorCore

enum BCryptPBKDF {
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
