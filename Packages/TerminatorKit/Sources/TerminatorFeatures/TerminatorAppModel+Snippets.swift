import Foundation
import TerminatorCore

extension TerminatorAppModel {
    func saveSnippet(_ draft: SnippetDraft) async -> SnippetProfile? {
        guard let repository = snippetRepository else { return nil }
        do {
            let existing = draft.id.flatMap { id in
                (snippets + archivedSnippets).first { $0.id == id }
            }
            let now = Date.now
            let snippet = try SnippetProfile(
                id: existing?.id ?? draft.id ?? UUID(),
                name: draft.name,
                script: draft.script,
                group: draft.group,
                tags: draft.tags,
                notes: draft.notes,
                lastUsedAt: existing?.lastUsedAt,
                externalID: existing?.externalID,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                deletedAt: existing?.deletedAt
            ).validated()
            try await repository.saveSnippet(snippet)
            await load()
            return snippets.first { $0.id == snippet.id } ?? snippet
        } catch {
            present(error)
            return nil
        }
    }

    public func deleteSnippet(id: UUID) async {
        guard let repository = snippetRepository else { return }
        do {
            try await repository.deleteSnippet(id: id)
            ArchiveHintStore.shared.arm()
            await load()
        } catch { present(error) }
    }

    public func restoreSnippet(id: UUID) async -> Bool {
        guard let repository = snippetRepository else { return false }
        do {
            try await repository.restoreSnippet(id: id)
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func purgeSnippet(id: UUID) async -> Bool {
        guard let repository = snippetRepository else { return false }
        do {
            try await repository.purgeSnippet(id: id)
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func importExternalSnippet(_ snippet: ExternalImportSnippet, source: ExternalImportSource) async -> Bool {
        guard let repository = snippetRepository else { return false }
        let name = snippet.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SnippetProfile(
            name: name.isEmpty ? "Snippet" : name,
            script: snippet.script,
            group: snippet.group.nilIfEmpty,
            tags: snippet.tags,
            notes: snippet.notes,
            externalID: "\(source.kind.rawValue)|\(snippet.id)"
        )
        do {
            try await repository.importSnippet(profile)
            await load()
            return true
        } catch {
            if !suppressesImportAnnouncements { present(error) }
            return false
        }
    }

    public func executeSnippet(_ snippet: SnippetProfile, on host: HostProfile) async -> HostActionResult {
        if let repository = snippetRepository {
            try? await repository.noteSnippetUsed(id: snippet.id)
        }
        guard let service = externalTerminalService else {
            let result = HostActionResult(succeeded: false, message: FeatureL10n.text(.snippetExecuteFailed))
            await recordActivity(host: host, title: snippet.name, output: result.message, displayName: logName(snippet, on: host))
            return result
        }
        do {
            let result = try await service.exec(host: host, command: snippet.script)
            let message = result.exitCode == 0
                ? FeatureL10n.text(.snippetExecuteFinished)
                : (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome = HostActionResult(
                succeeded: result.exitCode == 0,
                message: message.isEmpty ? FeatureL10n.text(.snippetExecuteFailed) : message
            )
            await recordActivity(
                host: host,
                title: snippet.name,
                output: activityText(command: snippet.script, result: result, message: outcome.message),
                displayName: logName(snippet, on: host)
            )
            return outcome
        } catch {
            let outcome = HostActionResult(succeeded: false, message: error.localizedDescription)
            await recordActivity(host: host, title: snippet.name, output: outcome.message, displayName: logName(snippet, on: host))
            return outcome
        }
    }

    private func logName(_ snippet: SnippetProfile, on host: HostProfile) -> String {
        let hostName = host.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownHost = hostName.isEmpty ? host.hostname : hostName
        return "\"\(snippet.name)\" on \(shownHost)"
    }

    public func snippetName(id: UUID) -> String? {
        (snippets + archivedSnippets).first { $0.id == id }?.name
    }
}
