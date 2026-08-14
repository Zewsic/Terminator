import Foundation
import Testing
import TerminatorCore
import TerminatorTestSupport
@testable import TerminatorSSH

@Test func encryptedLogRoundTripAndReconnect() async throws {
    let repository = InMemoryTerminatorStore()
    let secrets = InMemorySecretStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: "TerminatorLogTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = HostProfile(displayName: "Test", hostname: "localhost", username: "tester")
    let writer = try await SessionLogWriter.create(
        host: host, terminal: .wezTerm, repository: repository, secretStore: secrets, baseURL: directory
    )
    #expect(await writer.append(kind: .stdout, data: Data([0, 1, 2, 255])))
    await writer.markReconnect()
    await writer.finish()

    let metadata = await writer.metadata
    let clear = try await SessionLogWriter.readChunks(metadata: metadata, secretStore: secrets, baseURL: directory)
    #expect(clear.count == 2)
    #expect(clear[0].payload == Data([0, 1, 2, 255]))
    #expect(metadata.reconnectCount == 1)
    #expect(metadata.state == .complete)
    let encrypted = try Data(contentsOf: directory.appending(path: metadata.relativePath))
    #expect(!encrypted.contains(Data([0, 1, 2, 255])))
}

@Test func crashTruncatedLastChunkKeepsEarlierChunks() async throws {
    let repository = InMemoryTerminatorStore()
    let secrets = InMemorySecretStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: "TerminatorLogTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = try await SessionLogWriter.create(
        host: HostProfile(displayName: "Test", hostname: "localhost", username: "tester"),
        terminal: .terminal, repository: repository, secretStore: secrets, baseURL: directory
    )
    #expect(await writer.append(kind: .stdout, data: Data("first".utf8)))
    #expect(await writer.append(kind: .stderr, data: Data("second".utf8)))
    await writer.finish()
    let metadata = await writer.metadata
    let url = directory.appending(path: metadata.relativePath)
    var bytes = try Data(contentsOf: url)
    bytes.removeLast(8)
    try bytes.write(to: url)
    let chunks = try await SessionLogWriter.readChunks(metadata: metadata, secretStore: secrets, baseURL: directory)
    #expect(chunks.map { String(decoding: $0.payload, as: UTF8.self) } == ["first"])
}

@Test func retentionPreservesPinnedAndActiveLogs() async throws {
    let old = Date.now.addingTimeInterval(-100 * 86_400)
    let pinned = SessionLogMetadata(hostID: UUID(), hostDisplayName: "Pinned", terminal: .terminal,
        startedAt: old, endedAt: old, state: .complete, isPinned: true, relativePath: "pinned", encryptionKeyID: SecretID())
    let expired = SessionLogMetadata(hostID: UUID(), hostDisplayName: "Expired", terminal: .terminal,
        startedAt: old, endedAt: old, state: .complete, relativePath: "expired", encryptionKeyID: SecretID())
    let repository = InMemoryTerminatorStore(sessionLogs: [pinned, expired])
    let secrets = InMemorySecretStore()
    try await secrets.store(Data(repeating: 1, count: 32), for: pinned.encryptionKeyID)
    try await secrets.store(Data(repeating: 2, count: 32), for: expired.encryptionKeyID)
    let directory = FileManager.default.temporaryDirectory.appending(path: "TerminatorLogTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    FileManager.default.createFile(atPath: directory.appending(path: "pinned").path, contents: Data())
    FileManager.default.createFile(atPath: directory.appending(path: "expired").path, contents: Data())

    await SessionLogWriter.purgeExpired(olderThan: .now.addingTimeInterval(-90 * 86_400), repository: repository, secretStore: secrets, baseURL: directory)
    #expect(try await repository.sessionLog(id: pinned.id) != nil)
    #expect(try await repository.sessionLog(id: expired.id) == nil)
}
