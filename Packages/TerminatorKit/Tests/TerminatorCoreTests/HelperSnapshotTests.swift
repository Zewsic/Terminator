import Foundation
import Testing
@testable import TerminatorCore

@Suite("Helper snapshot")
struct HelperSnapshotTests {
    @Test("Parses status and containers from a helper payload")
    func parsesSnapshot() throws {
        let hostID = UUID()
        let payload = """
        {
          "uptime": 3600,
          "load": [0.2, 0.4, 0.5],
          "cores": [{"name": "cpu", "usage": 0.25}],
          "memory": {"total": 1000, "used": 400, "available": 600, "swapTotal": 200, "swapUsed": 10, "cached": 50},
          "disks": [{"name": "sda", "fileSystem": "ext4", "mount": "/", "total": 5000, "used": 1000, "read": 10, "write": 4}],
          "network": {"receive": 12, "transmit": 8, "interfaces": [{"name": "eth0", "receive": 12, "transmit": 8}]},
          "processes": [{"pid": 7, "user": "root", "name": "sshd", "cpu": 0.2, "memory": 4096, "read": 3, "write": 1}],
          "containers": [{
            "id": "abc",
            "name": "web",
            "image": "nginx",
            "imageID": "sha256:0123456789abcdef",
            "state": "running",
            "health": "healthy",
            "labels": {"com.docker.compose.project": "stack"}
          }],
          "services": []
        }
        """.data(using: .utf8)!
        let parsed = try #require(HelperSnapshot.parse(payload, hostID: hostID, endpoint: .host(id: hostID, name: "edge")))
        #expect(parsed.0.uptime == 3600)
        #expect(parsed.0.load1 == 0.2)
        #expect(parsed.0.cores.first?.usage == 0.25)
        #expect(parsed.0.memory.used == 400)
        #expect(parsed.0.disks.first?.mount == "/")
        #expect(parsed.0.network.receiveBytesPerSecond == 12)
        #expect(parsed.0.disks.first?.readBytesPerSecond == 10)
        #expect(parsed.0.network.interfaces.first?.name == "eth0")
        #expect(parsed.0.processes.first?.name == "sshd")
        #expect(parsed.0.processes.first?.memory == 4096)
        #expect(parsed.1.count == 1)
        #expect(parsed.1[0].name == "web")
        #expect(parsed.1[0].imageID == "0123456789ab")
        if case .compose(let project, _, _) = parsed.1[0].placement {
            #expect(project == "stack")
        } else {
            Issue.record("Expected a compose placement")
        }
    }

    @Test("Reads the helper version and decides when it is older")
    func comparesVersions() throws {
        let payload = #"{"version":"2","uptime":1,"load":[],"containers":[]}"#.data(using: .utf8)!
        #expect(HelperSnapshot.reportedVersion(payload) == "2")
        #expect(HelperSnapshot.reportedVersion(#"{"uptime":1}"#.data(using: .utf8)!) == nil)
        #expect(HelperVersion.isOlder("1", than: "2"))
        #expect(HelperVersion.isOlder("1.9", than: "1.10"))
        #expect(HelperVersion.isOlder("2", than: "2.0") == false)
        #expect(HelperVersion.isOlder("3", than: "2") == false)
        #expect(HelperVersion.isOlder(HelperSnapshot.version, than: HelperSnapshot.version) == false)
    }
}
