import Foundation
import Testing
import TerminatorCore
@testable import TerminatorSSH

@Test func connectionControlFramesRoundTrip() throws {
    let host = HostProfile(displayName: "Prod", hostname: "example.com", username: "deploy")
    let frames: [ConnectionControlFrame] = [
        .request(id: UUID(), .connect(hostID: host.id, terminal: .ghostty)),
        .request(id: UUID(), .command(hostID: host.id)),
        .response(id: UUID(), .ok),
        .response(id: UUID(), .phase(.reconnecting(attempt: 2))),
        .response(id: UUID(), .command("/usr/bin/terminator-attach")),
        .request(id: UUID(), .exec(hostID: host.id, command: "uname")),
        .response(id: UUID(), .exec(stdout: "Linux\n", stderr: "", exitCode: 0)),
        .response(id: UUID(), .connected(detectedOS: DetectedHostOS(id: "ubuntu", name: "Ubuntu", version: "24.04"))),
        .event(.phase(hostID: host.id, .connected)),
        .event(.prompt(ConnectionPromptEnvelope(hostID: host.id, kind: .username(host: host)))),
        .event(.prompt(ConnectionPromptEnvelope(kind: .keychain(reason: "Touch ID")))),
    ]
    for frame in frames {
        let encoded = try ConnectionControlCodec.line(from: frame)
        #expect(encoded.last == 0x0A)
        let decoded = try ConnectionControlCodec.frame(from: encoded.dropLast())
        let left = try ConnectionControlCodec.encoder().encode(frame)
        let right = try ConnectionControlCodec.encoder().encode(decoded)
        #expect(left == right)
    }
}


