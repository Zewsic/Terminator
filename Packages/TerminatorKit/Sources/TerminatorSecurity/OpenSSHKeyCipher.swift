import CBcryptPBKDF
import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TerminatorCore

enum AESCTR {
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

enum AESCBC {
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
