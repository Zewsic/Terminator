import Foundation
import Testing
@testable import TerminatorCore

@Suite("Host profile validation")
struct HostProfileTests {
    @Test("Trims values and normalizes tags")
    func normalizesHost() throws {
        let host = HostProfile(
            displayName: "  Production  ",
            hostname: " prod.example.com ",
            username: " deploy ",
            group: " Servers ",
            tags: [" production ", "ssh", "ssh"]
        )

        let result = try host.validated()

        #expect(result.displayName == "Production")
        #expect(result.hostname == "prod.example.com")
        #expect(result.username == "deploy")
        #expect(result.group == "Servers")
        #expect(result.tags == ["production", "ssh"])
    }

    @Test("Rejects an invalid port")
    func rejectsInvalidPort() {
        let host = HostProfile(displayName: "Host", hostname: "example.com", port: 0, username: "root")
        #expect(throws: HostValidationError.invalidPort) {
            try host.validated()
        }
    }

    @Test("Session persistence round-trips through Codable")
    func sessionPersistenceCodable() throws {
        let host = HostProfile(
            displayName: "Lab",
            hostname: "lab.example.com",
            username: "root",
            sessionPersistence: .tmux,
            connectCommands: "cd /opt\nsource ./env"
        )
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        #expect(decoded.sessionPersistence == .tmux)
        #expect(decoded.remoteShell.preset == .loginShell)
        #expect(decoded.connectCommands == "cd /opt\nsource ./env")
        #expect(decoded.detectedOS == nil)

        let withOS = HostProfile(
            displayName: "Lab",
            hostname: "lab.example.com",
            authentication: .manual(username: "root", authenticationMethods: []),
            detectedOS: DetectedHostOS(id: "ubuntu", name: "Ubuntu", version: "24.04")
        )
        let encodedOS = try JSONEncoder().encode(withOS)
        let decodedOS = try JSONDecoder().decode(HostProfile.self, from: encodedOS)
        #expect(decodedOS.detectedOS?.tag == "Ubuntu 24.04")

        struct Legacy: Encodable {
            var id = UUID()
            var displayName = "Old"
            var hostname = "old.example.com"
            var port = 22
            var username = "root"
            var tags: [String] = []
            var notes = ""
            var createdAt = Date()
            var updatedAt = Date()
        }
        let legacy = try JSONEncoder().encode(Legacy())
        let migrated = try JSONDecoder().decode(HostProfile.self, from: legacy)
        #expect(migrated.sessionPersistence == .none)
        #expect(migrated.connectCommands.isEmpty)
    }
    @Test("Normalizes an empty Docker prefix and rejects shell syntax")
    func dockerCommandPrefix() throws {
        let empty = HostProfile(
            displayName: "Edge", hostname: "edge.example.com", username: "root", dockerCommandPrefix: "  "
        )
        #expect(try empty.validated().dockerCommandPrefix == "docker")
        let injected = HostProfile(
            displayName: "Edge", hostname: "edge.example.com", username: "root",
            dockerCommandPrefix: "docker; rm -rf /"
        )
        #expect(throws: HostValidationError.invalidDockerCommandPrefix) {
            try injected.validated()
        }
    }

}
