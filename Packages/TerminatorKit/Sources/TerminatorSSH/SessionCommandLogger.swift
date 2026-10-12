import Foundation
import TerminatorCore

public struct SessionCommandLogger: ActivityLogRecording, Sendable {
    private let repository: any SessionLogRepository
    private let secretStore: any SecretStore
    private let baseURL: URL

    public init(repository: any SessionLogRepository, secretStore: any SecretStore, baseURL: URL) {
        self.repository = repository
        self.secretStore = secretStore
        self.baseURL = baseURL
    }

    public func record(host: HostProfile, title: String, output: String, displayName: String?) async {
        do {
            let writer = try await SessionLogWriter.create(
                host: host, terminal: .other, repository: repository, secretStore: secretStore, baseURL: baseURL,
                displayName: displayName
            )
            _ = await writer.append(kind: .status, data: Data(title.utf8))
            if !output.isEmpty {
                _ = await writer.append(kind: .stdout, data: Data(output.utf8))
            }
            await writer.finish()
        } catch {
            return
        }
    }
}
