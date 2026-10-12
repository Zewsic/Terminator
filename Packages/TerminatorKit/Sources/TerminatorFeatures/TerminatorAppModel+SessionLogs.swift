import Foundation
import Observation
import TerminatorCore

extension TerminatorAppModel {
    public var visibleSessionLogs: [SessionLogMetadata] {
        sessionLogs.filter { $0.deletedAt == nil }
    }

    public var archivedSessionLogs: [SessionLogMetadata] {
        sessionLogs.filter { $0.deletedAt != nil }
    }

    public func reloadSessionLogs() async {
        guard let sessionLogRepository else { return }
        if let logs = try? await sessionLogRepository.listSessionLogs() {
            sessionLogs = logs
        }
    }

    public func reloadHistory() async {
        if let entries = try? await historyRepository.listHistory(entity: nil) {
            history = entries
        }
    }

    public func setLogPinned(_ id: UUID, pinned: Bool) async {
        guard let sessionLogRepository, var log = sessionLogs.first(where: { $0.id == id }) else { return }
        do { log.isPinned = pinned; try await sessionLogRepository.saveSessionLog(log); await reloadSessionLogs() }
        catch { present(error) }
    }

    public func archiveLog(_ log: SessionLogMetadata) async {
        guard let sessionLogRepository, log.state != .active, log.deletedAt == nil else { return }
        var archived = log
        archived.deletedAt = .now
        do {
            try await sessionLogRepository.saveSessionLog(archived)
            ArchiveHintStore.shared.arm()
            await reloadSessionLogs()
        } catch { present(error) }
    }

    public func restoreLog(_ log: SessionLogMetadata) async -> Bool {
        guard let sessionLogRepository else { return false }
        var restored = log
        restored.deletedAt = nil
        do {
            try await sessionLogRepository.saveSessionLog(restored)
            await reloadSessionLogs()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func deleteLog(_ log: SessionLogMetadata) async {
        guard let sessionLogRepository, log.state != .active else { return }
        do {
            if let sessionLogBaseURL {
                try? FileManager.default.removeItem(at: sessionLogBaseURL.appending(path: log.relativePath))
            }
            try await sessionLogRepository.deleteSessionLog(id: log.id)
            try? await secretStore.purge(id: log.encryptionKeyID)
            await reloadSessionLogs()
        } catch { present(error) }
    }

    public func exportLog(_ log: SessionLogMetadata) async {
        guard let sessionLogExporter else { return }
        do { _ = try await sessionLogExporter.export(log) }
        catch { present(error) }
    }

    public func sessionLogTranscript(_ log: SessionLogMetadata) async -> String? {
        guard let sessionLogExporter, log.state != .active else { return nil }
        do { return try await sessionLogExporter.transcript(log) }
        catch {
            present(error)
            return nil
        }
    }

}
