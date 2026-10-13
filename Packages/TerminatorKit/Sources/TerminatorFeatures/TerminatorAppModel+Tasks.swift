import Foundation
import TerminatorCore

extension TerminatorAppModel {
    func refreshContainers() async {
        await tunnelController?.refreshDocker()
    }

    func loadServerTasks(hostID: UUID) async {
        serverTasksLoading.insert(hostID)
        defer { serverTasksLoading.remove(hostID) }
        guard let call = await helperCall(hostID: hostID) else {
            serverTasksOffline.insert(hostID)
            return
        }
        do {
            let data = try await HelperPoll.tasks(
                hostname: call.hostname,
                port: call.port,
                token: call.token,
                certificateDER: call.certificateDER
            )
            let parsed = try parseTaskIndex(data, hostID: hostID)
            serverTasksOffline.remove(hostID)
            serverCrontabs[hostID] = parsed.document
            serverTaskCapabilities[hostID] = parsed.capabilities
            serverTasks[hostID] = parsed.tasks
        } catch {
            if helperOnline.contains(hostID) {
                serverTasksOffline.remove(hostID)
            } else {
                serverTasksOffline.insert(hostID)
            }
            present(error)
        }
    }

    func loadTaskLastRuns(hostID: UUID) async {
        guard let call = await helperCall(hostID: hostID) else { return }
        let lines = (try? await HelperPoll.executions(
            hostname: call.hostname,
            port: call.port,
            token: call.token,
            certificateDER: call.certificateDER,
            limit: 400
        )) ?? []
        let executions = TaskExecutionParser.parse(lines)
        var dates: [UUID: Date] = [:]
        for task in serverTasks[hostID] ?? [] {
            let command = task.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            let latest = executions.compactMap { execution -> Date? in
                guard let recordedAt = execution.recordedAt, execution.summary.contains(command) else { return nil }
                return recordedAt
            }.max()
            if let latest { dates[task.id] = latest }
        }
        taskLastRuns[hostID] = dates
    }

    func loadTaskExecutions(hostID: UUID, limit: Int) async {
        guard let call = await helperCall(hostID: hostID) else { return }
        let lines = (try? await HelperPoll.executions(
            hostname: call.hostname,
            port: call.port,
            token: call.token,
            certificateDER: call.certificateDER,
            limit: limit
        )) ?? []
        serverTaskExecutions[hostID] = TaskExecutionParser.parse(lines)
    }

    func saveServerTask(hostID: UUID, existing: ScheduledTask?, draft: TaskDraft) async -> Bool {
        guard draft.backend == .cron, existing?.writable != false else {
            present(id: "task-save", message: FeatureL10n.text(.tasksSaveFailed))
            return false
        }
        guard var document = serverCrontabs[hostID] else {
            present(id: "task-save", message: FeatureL10n.text(.tasksSaveFailed))
            return false
        }
        let task = ScheduledTask(
            id: existing?.id ?? UUID(),
            hostID: hostID,
            backend: .cron,
            scope: .user,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            command: draft.command.trimmingCharacters(in: .whitespacesAndNewlines),
            schedule: draft.schedule,
            enabled: draft.enabled,
            writable: true
        )
        guard !task.command.isEmpty else {
            present(id: "task-save", message: FeatureL10n.text(.tasksSaveFailed))
            return false
        }
        let environment = CrontabEnvironment(shell: draft.shell, path: draft.path, mailto: draft.mailto)
        document = document.replacing(task, environment: environment)
        return await writeCrontab(hostID: hostID, document: document, before: existing, after: task, operation: existing == nil ? .created : .updated)
    }

    func deleteServerTask(hostID: UUID, task: ScheduledTask, draft: TaskDraft) async -> Bool {
        guard task.writable, task.backend == .cron, var document = serverCrontabs[hostID] else {
            present(id: "task-save", message: FeatureL10n.text(.tasksSaveFailed))
            return false
        }
        let environment = CrontabEnvironment(shell: draft.shell, path: draft.path, mailto: draft.mailto)
        document = document.removing(task.id, environment: environment)
        return await writeCrontab(hostID: hostID, document: document, before: task, after: nil, operation: .deleted)
    }

    private func writeCrontab(
        hostID: UUID,
        document: CrontabDocument,
        before: ScheduledTask?,
        after: ScheduledTask?,
        operation: HistoryOperation
    ) async -> Bool {
        guard let call = await helperCall(hostID: hostID) else {
            serverTasksOffline.insert(hostID)
            present(id: "task-save", message: FeatureL10n.text(.tasksHelperOffline))
            return false
        }
        do {
            let result = try await HelperPoll.saveCrontab(
                hostname: call.hostname,
                port: call.port,
                token: call.token,
                certificateDER: call.certificateDER,
                expectedHash: document.hash,
                body: document.rendered()
            )
            if result.conflict {
                await loadServerTasks(hostID: hostID)
                present(id: "task-conflict", message: FeatureL10n.text(.tasksConflict))
                return false
            }
            try await recordTaskHistory(hostID: hostID, before: before, after: after, operation: operation)
            await loadServerTasks(hostID: hostID)
            if let hash = result.hash {
                serverCrontabs[hostID]?.hash = hash
            }
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func recordTaskHistory(
        hostID: UUID,
        before: ScheduledTask?,
        after: ScheduledTask?,
        operation: HistoryOperation
    ) async throws {
        let hostName = hosts.first { $0.id == hostID }?.displayName ?? ""
        let encoder = JSONEncoder()
        let entityID = after?.id ?? before?.id ?? UUID()
        try await historyRepository.recordHistory(
            entity: .task,
            entityID: entityID,
            operation: operation,
            before: try before.map { try encoder.encode(snapshot($0, hostName: hostName)) },
            after: try after.map { try encoder.encode(snapshot($0, hostName: hostName)) }
        )
        await reloadHistory()
    }

    private func snapshot(_ task: ScheduledTask, hostName: String) -> TaskHistorySnapshot {
        TaskHistorySnapshot(
            name: task.listTitle,
            command: task.command,
            schedule: TaskScheduleText.summary(task.schedule, backend: task.backend),
            backend: task.backend.title,
            enabled: task.enabled,
            host: hostName
        )
    }

    private func parseTaskIndex(_ data: Data, hostID: UUID) throws -> (document: CrontabDocument, tasks: [ScheduledTask], capabilities: TaskCapabilities) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelperInstallError.remote(FeatureL10n.text(.tasksSaveFailed))
        }
        let text = object["crontab"] as? String ?? ""
        let hash = object["crontabHash"] as? String ?? ""
        let flags = object["capabilities"] as? [String: Any] ?? [:]
        let capabilities = TaskCapabilities(
            cron: flags["cron"] as? Bool ?? false,
            systemd: flags["systemd"] as? Bool ?? false,
            at: flags["at"] as? Bool ?? false,
            anacron: flags["anacron"] as? Bool ?? false,
            launchd: flags["launchd"] as? Bool ?? false,
            isRoot: flags["root"] as? Bool ?? false,
            systemCron: flags["systemCron"] as? Bool ?? false
        )
        let document = CrontabDocument.parse(hostID: hostID, text: text, hash: hash, writable: capabilities.cron)
        var tasks = document.entries.map(\.task)
        let files = object["systemCron"] as? [[String: Any]] ?? []
        for file in files {
            let path = file["path"] as? String ?? ""
            let body = file["body"] as? String ?? ""
            let parsed = CrontabDocument.parse(hostID: hostID, text: body, hash: "", writable: false, salt: path)
            tasks.append(contentsOf: parsed.entries.map { entry in
                var task = entry.task
                task.scope = .system
                task.writable = false
                return task
            })
        }
        return (document, tasks, capabilities)
    }
}
