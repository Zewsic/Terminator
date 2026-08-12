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
}
