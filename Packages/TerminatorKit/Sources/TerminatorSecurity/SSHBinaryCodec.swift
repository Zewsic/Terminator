import CBcryptPBKDF
import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TerminatorCore

struct SSHWriter {
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

struct SSHReader {
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
