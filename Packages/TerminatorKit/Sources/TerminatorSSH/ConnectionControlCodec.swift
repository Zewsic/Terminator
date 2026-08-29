import Foundation
import TerminatorCore

enum ConnectionControlCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func line(from frame: ConnectionControlFrame) throws -> Data {
        var data = try encoder().encode(frame)
        data.append(0x0A)
        return data
    }

    static func frame(from line: Data) throws -> ConnectionControlFrame {
        try decoder().decode(ConnectionControlFrame.self, from: line)
    }
}
