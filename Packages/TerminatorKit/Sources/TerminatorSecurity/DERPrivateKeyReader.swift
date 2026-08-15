import CBcryptPBKDF
import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TerminatorCore

struct RSAPrivateValues {
    var n: Data
    var e: Data
    var d: Data
    var p: Data
    var q: Data
    var iqmp: Data
}

enum DERReader {
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
