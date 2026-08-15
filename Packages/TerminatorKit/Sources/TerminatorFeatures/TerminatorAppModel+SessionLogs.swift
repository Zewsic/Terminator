import Foundation
import Observation
import TerminatorCore

extension TerminatorAppModel {
    public func setLogPinned(_ id: UUID, pinned: Bool) async {
        guard let sessionLogRepository, var log = sessionLogs.first(where: { $0.id == id }) else { return }
        do { log.isPinned = pinned; try await sessionLogRepository.saveSessionLog(log); await load() }
        catch { present(error) }
    }

    public func deleteLog(_ log: SessionLogMetadata) async {
        guard let sessionLogRepository, log.state != .active else { return }
        do {
            if let sessionLogBaseURL {
                try? FileManager.default.removeItem(at: sessionLogBaseURL.appending(path: log.relativePath))
            }
            try await sessionLogRepository.deleteSessionLog(id: log.id)
            try? await secretStore.purge(id: log.encryptionKeyID)
            await load()
        } catch { present(error) }
    }

    public func exportLog(_ log: SessionLogMetadata) async {
        guard let sessionLogExporter else { return }
        do { _ = try await sessionLogExporter.export(log) }
        catch { present(error) }
    }

}
