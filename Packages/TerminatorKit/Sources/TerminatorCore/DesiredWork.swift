import Foundation

public struct DesiredTerminal: Codable, Equatable, Sendable {
    public var token: String
    public var hostID: UUID
    public var columns: Int
    public var rows: Int
    public var remoteCommand: String?

    public init(token: String, hostID: UUID, columns: Int, rows: Int, remoteCommand: String? = nil) {
        self.token = token
        self.hostID = hostID
        self.columns = columns
        self.rows = rows
        self.remoteCommand = remoteCommand
    }
}

public struct DesiredWork: Codable, Equatable, Sendable {
    public var tunnelIDs: [UUID]
    public var terminals: [DesiredTerminal]

    public init(tunnelIDs: [UUID] = [], terminals: [DesiredTerminal] = []) {
        self.tunnelIDs = tunnelIDs
        self.terminals = terminals
    }
}

public actor DesiredWorkStore {
    public static let fileName = "desired-work.json"

    private let fileURL: URL
    private var work: DesiredWork

    public init(directory: URL) {
        fileURL = directory.appending(path: Self.fileName)
        work = Self.read(fileURL) ?? DesiredWork()
    }

    public func current() -> DesiredWork { work }

    public func addTerminal(_ terminal: DesiredTerminal) {
        work.terminals.removeAll { $0.token == terminal.token }
        work.terminals.append(terminal)
        persist()
    }

    public func updateTerminal(token: String, columns: Int, rows: Int) {
        guard let index = work.terminals.firstIndex(where: { $0.token == token }) else { return }
        work.terminals[index].columns = columns
        work.terminals[index].rows = rows
        persist()
    }

    public func removeTerminal(token: String) {
        let previous = work.terminals.count
        work.terminals.removeAll { $0.token == token }
        if work.terminals.count != previous { persist() }
    }

    public func removeTerminals(hostID: UUID) {
        let previous = work.terminals.count
        work.terminals.removeAll { $0.hostID == hostID }
        if work.terminals.count != previous { persist() }
    }

    public func addTunnel(_ id: UUID) {
        guard !work.tunnelIDs.contains(id) else { return }
        work.tunnelIDs.append(id)
        persist()
    }

    public func removeTunnel(_ id: UUID) {
        let previous = work.tunnelIDs.count
        work.tunnelIDs.removeAll { $0 == id }
        if work.tunnelIDs.count != previous { persist() }
    }

    public func removeTunnels(_ ids: [UUID]) {
        let drop = Set(ids)
        guard !drop.isEmpty else { return }
        let previous = work.tunnelIDs.count
        work.tunnelIDs.removeAll { drop.contains($0) }
        if work.tunnelIDs.count != previous { persist() }
    }

    private func persist() {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(work)
            let temporary = directory.appending(path: "desired-work.\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            // A failed write leaves the previous file in place. The in-memory
            // copy stays current so a later successful write can catch up.
        }
    }

    private static func read(_ url: URL) -> DesiredWork? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DesiredWork.self, from: data)
    }
}
