import CryptoKit
import Compression
import Foundation
import TerminatorCore

public enum SessionLogError: LocalizedError, Sendable {
    case invalidFormat
    case missingLog

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: SSHL10n.text(.errorInvalidLogFormat)
        case .missingLog: SSHL10n.text(.errorMissingLog)
        }
    }
}

public struct SessionLogChunk: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var kind: SessionLogEventKind
    public var payload: Data
}

public actor SessionLogWriter {
    private static let magic = Data("TERMINATOR-SESSION-LOG-V1\0".utf8)

    public private(set) var metadata: SessionLogMetadata
    private let repository: any SessionLogRepository
    private let secretStore: any SecretStore
    private let baseURL: URL
    private let key: SymmetricKey
    private var handle: FileHandle?
    private var failed = false

    public static func create(
        host: HostProfile,
        terminal: TerminalApplication,
        repository: any SessionLogRepository,
        secretStore: any SecretStore,
        baseURL: URL
    ) async throws -> SessionLogWriter {
        let id = UUID()
        let keyID = SecretID()
        let keyData = randomData(count: 32)
        try await secretStore.store(keyData, for: keyID)
        let relativePath = "\(id.uuidString).tlog"
        var metadata = SessionLogMetadata(
            id: id, hostID: host.id, hostDisplayName: host.displayName,
            terminal: terminal, relativePath: relativePath, encryptionKeyID: keyID
        )
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            let url = baseURL.appending(path: relativePath)
            guard FileManager.default.createFile(atPath: url.path, contents: magic) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try await repository.saveSessionLog(metadata)
            return try SessionLogWriter(
                metadata: metadata, repository: repository, secretStore: secretStore,
                baseURL: baseURL, keyData: keyData
            )
        } catch {
            metadata.state = .incomplete
            try? await secretStore.purge(id: keyID)
            throw error
        }
    }

    private init(
        metadata: SessionLogMetadata,
        repository: any SessionLogRepository,
        secretStore: any SecretStore,
        baseURL: URL,
        keyData: Data
    ) throws {
        self.metadata = metadata
        self.repository = repository
        self.secretStore = secretStore
        self.baseURL = baseURL
        self.key = SymmetricKey(data: keyData)
        self.handle = try FileHandle(forWritingTo: baseURL.appending(path: metadata.relativePath))
        try self.handle?.seekToEnd()
    }

    @discardableResult
    public func append(kind: SessionLogEventKind, data: Data, timestamp: Date = .now) async -> Bool {
        guard !failed, let handle else { return false }
        do {
            let clear = try JSONEncoder().encode(SessionLogChunk(timestamp: timestamp, kind: kind, payload: data))
            let box = try AES.GCM.seal(try Self.compress(clear), using: key)
            guard let combined = box.combined, combined.count <= Int(UInt32.max) else {
                throw SessionLogError.invalidFormat
            }
            var length = UInt32(combined.count).bigEndian
            let lengthData = withUnsafeBytes(of: &length) { Data($0) }
            try handle.write(contentsOf: lengthData)
            try handle.write(contentsOf: combined)
            metadata.byteCount += Int64(data.count)
            try await repository.saveSessionLog(metadata)
            return true
        } catch {
            failed = true
            metadata.state = .incomplete
            metadata.endedAt = .now
            try? await repository.saveSessionLog(metadata)
            try? handle.close()
            self.handle = nil
            return false
        }
    }

    public func markReconnect() async {
        metadata.reconnectCount += 1
        _ = await append(kind: .status, data: Data("Reconnected with a new remote shell".utf8))
    }

    public func finish() async {
        guard metadata.endedAt == nil else { return }
        metadata.endedAt = .now
        if metadata.state == .active { metadata.state = .complete }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        try? await repository.saveSessionLog(metadata)
    }

    public static func readChunks(
        metadata: SessionLogMetadata,
        secretStore: any SecretStore,
        baseURL: URL
    ) async throws -> [SessionLogChunk] {
        let keyData = try await secretStore.read(id: metadata.encryptionKeyID)
        let key = SymmetricKey(data: keyData)
        let url = baseURL.appending(path: metadata.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SessionLogError.missingLog }
        let data = try Data(contentsOf: url)
        guard data.starts(with: magic) else { throw SessionLogError.invalidFormat }
        var offset = magic.count
        var chunks: [SessionLogChunk] = []
        while offset + 4 <= data.count {
            let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            let end = offset + Int(length)
            guard end <= data.count else { break }
            let box = try AES.GCM.SealedBox(combined: Data(data[offset..<end]))
            let clear = try decompress(AES.GCM.open(box, using: key))
            chunks.append(try JSONDecoder().decode(SessionLogChunk.self, from: clear))
            offset = end
        }
        return chunks
    }

    public static func purgeExpired(
        olderThan cutoff: Date,
        repository: any SessionLogRepository,
        secretStore: any SecretStore,
        baseURL: URL
    ) async {
        guard let logs = try? await repository.listSessionLogs() else { return }
        for log in logs where !log.isPinned && log.state != .active && (log.endedAt ?? log.startedAt) < cutoff {
            let url = baseURL.appending(path: log.relativePath)
            try? FileManager.default.removeItem(at: url)
            try? await secretStore.purge(id: log.encryptionKeyID)
            try? await repository.deleteSessionLog(id: log.id)
        }
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func compress(_ input: Data) throws -> Data {
        try transform(input, initialCapacity: max(256, input.count + 128), decode: false)
    }

    private static func decompress(_ input: Data) throws -> Data {
        try transform(input, initialCapacity: max(1_024, input.count * 4), decode: true)
    }

    private static func transform(_ input: Data, initialCapacity: Int, decode: Bool) throws -> Data {
        var capacity = initialCapacity
        while capacity <= 128 * 1_024 * 1_024 {
            var destination = [UInt8](repeating: 0, count: capacity)
            let count = input.withUnsafeBytes { source in
                destination.withUnsafeMutableBytes { output in
                    guard let src = source.bindMemory(to: UInt8.self).baseAddress,
                          let dst = output.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return decode
                        ? compression_decode_buffer(dst, capacity, src, input.count, nil, COMPRESSION_ZLIB)
                        : compression_encode_buffer(dst, capacity, src, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            if count > 0 { return Data(destination.prefix(count)) }
            capacity *= 2
        }
        throw SessionLogError.invalidFormat
    }
}
