import Foundation
import Observation
import TerminatorCore

extension TerminatorAppModel {
    public func saveHost(_ draft: HostDraft) async -> Bool {
        var journal = SecretMutationJournal(secretStore: secretStore)
        do {
            let existing = draft.id.flatMap { id in hosts.first(where: { $0.id == id }) }
            let now = Date.now
            let authentication: HostAuthentication
            if draft.usesIdentity, let identityID = draft.identityID {
                authentication = .identity(identityID)
            } else {
                var methods: [AuthenticationMethod] = []
                for method in draft.authenticationMethods {
                    switch method.kind {
                    case .accessKey(let credentialID):
                        methods.append(.accessKey(credentialID: credentialID))
                    case .password(let existingSecretID):
                        let value = method.password
                        let shouldReplace = method.passwordChanged || (existingSecretID == nil && !value.isEmpty)
                        if shouldReplace, !value.isEmpty {
                            let secretID = try await journal.create(Data(value.utf8))
                            methods.append(.password(secretID: secretID))
                            journal.removeAfterCommit(existingSecretID)
                        } else if shouldReplace, let existingSecretID {
                            journal.removeAfterCommit(existingSecretID)
                        } else if let existingSecretID {
                            methods.append(.password(secretID: existingSecretID))
                        }
                    }
                }
                authentication = .manual(username: draft.username, authenticationMethods: methods)
            }
            let host = HostProfile(
                id: existing?.id ?? draft.id ?? UUID(),
                displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? draft.hostname
                    : draft.displayName,
                hostname: draft.hostname,
                port: draft.port,
                authentication: authentication,
                group: draft.group,
                tags: draft.tags,
                notes: draft.notes,
                sessionPersistence: draft.sessionPersistence,
                remoteShell: draft.remoteShell,
                connectCommands: draft.connectCommands,
                connectCommandSegments: ConnectCommandScript.stored(draft.connectCommandSegments),
                detectedOS: existing?.detectedOS,
                alwaysConnected: draft.alwaysConnected,
                dockerCommandPrefix: draft.dockerCommandPrefix,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                deletedAt: existing?.deletedAt
            )
            try await hostRepository.saveHost(host)
            await journal.commitRemovals()
            await load()
            if host.alwaysConnected || existing?.alwaysConnected == true {
                do { try await externalTerminalService?.prepare(hostID: host.id) }
                catch { present(error) }
            }
            return true
        } catch {
            await journal.rollbackCreatedSecrets()
            present(error)
            return false
        }
    }

    public func loadHostPassword(into draft: HostDraft) async -> HostDraft {
        var copy = draft
        guard let index = copy.authenticationMethods.firstIndex(where: { method in
            if case .password(let id) = method.kind { return id != nil }
            return false
        }), case .password(let secretID?) = copy.authenticationMethods[index].kind else {
            return copy
        }
        do {
            let data = try await secretStore.read(id: secretID)
            guard let value = String(data: data, encoding: .utf8) else {
                throw CredentialValidationError.missingSecret
            }
            copy.authenticationMethods[index].password = value
            copy.authenticationMethods[index].passwordChanged = false
        } catch {
            present(error)
        }
        return copy
    }

    public func deleteHost(id: UUID) async {
        do {
            try await hostRepository.deleteHost(id: id)
            ArchiveHintStore.shared.arm()
            await load()
        } catch { present(error) }
    }

    public func restoreHost(id: UUID) async -> Bool {
        do {
            try await hostRepository.restoreHost(id: id)
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }

    public func purgeHost(id: UUID) async -> Bool {
        do {
            try await hostRepository.purgeHost(id: id)
            await load()
            return true
        } catch {
            present(error)
            return false
        }
    }
    public func installPublicKey(_ line: String, on host: HostProfile) async -> HostActionResult {
        guard let command = AuthorizedKeyLine.installCommand(line) else {
            let result = HostActionResult(succeeded: false, message: FeatureL10n.text(.keyExportInvalid))
            await recordActivity(host: host, title: FeatureL10n.text(.featureAccessKeyEditorExportToHost), output: result.message)
            return result
        }
        guard let service = externalTerminalService else {
            let result = HostActionResult(succeeded: false, message: FeatureL10n.text(.keyExportFailed))
            await recordActivity(host: host, title: FeatureL10n.text(.featureAccessKeyEditorExportToHost), output: result.message)
            return result
        }
        do {
            let result = try await service.exec(host: host, command: command)
            let outcome: HostActionResult
            if result.stdout.contains("TERMINATOR_ALREADY") {
                outcome = HostActionResult(succeeded: true, message: FeatureL10n.text(.keyExportAlready))
            } else if result.exitCode == 0, result.stdout.contains("TERMINATOR_INSTALLED") {
                outcome = HostActionResult(succeeded: true, message: FeatureL10n.text(.keyExportInstalled))
            } else {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                outcome = HostActionResult(
                    succeeded: false,
                    message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? FeatureL10n.text(.keyExportFailed)
                        : message
                )
            }
            await recordActivity(
                host: host,
                title: FeatureL10n.text(.featureAccessKeyEditorExportToHost),
                output: activityText(command: command, result: result, message: outcome.message)
            )
            return outcome
        } catch {
            let outcome = HostActionResult(succeeded: false, message: error.localizedDescription)
            await recordActivity(host: host, title: FeatureL10n.text(.featureAccessKeyEditorExportToHost), output: outcome.message)
            return outcome
        }
    }

    func recordActivity(host: HostProfile, title: String, output: String, displayName: String? = nil) async {
        await activityLog?.record(host: host, title: title, output: output, displayName: displayName)
    }

    func activityText(command: String, result: SSHExecResult, message: String) -> String {
        var lines = ["$ \(command)", result.stdout, result.stderr, "exit \(result.exitCode)", message]
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }


}
