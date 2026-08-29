#if !APP_STORE
import Foundation
import TerminatorCore

/// A deliberately non-secret catalog consumed by the bundled Raycast extension.
/// It contains neither usernames nor authentication material.
struct RaycastServerCatalog: Sendable {
    private struct Entry: Codable {
        let id: UUID
        let name: String
        let hostname: String
        let port: Int
        let group: String?
        let tags: [String]
    }

    private struct Document: Codable {
        let version = 1
        let servers: [Entry]
    }

    func write(hosts: [HostProfile], applicationSupportURL: URL) throws {
        let directory = applicationSupportURL
            .appending(path: "Integrations/Raycast", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let document = Document(servers: hosts.map {
            Entry(id: $0.id, name: $0.displayName, hostname: $0.hostname, port: $0.port, group: $0.group, tags: $0.tags)
        })
        let data = try JSONEncoder().encode(document)
        let destination = directory.appending(path: "servers.json")
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
#endif
