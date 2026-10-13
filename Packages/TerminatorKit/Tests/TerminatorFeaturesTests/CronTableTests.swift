import Foundation
import Testing
@testable import TerminatorFeatures

struct CronTableTests {
    @Test func parsesDailyAndKeepsTheMarker() {
        let host = UUID()
        let id = UUID()
        let text = """
        SHELL=/bin/sh
        # terminator:\(id.uuidString)
        15 3 * * * /usr/bin/backup
        """
        let document = CrontabDocument.parse(hostID: host, text: text, hash: "abc", writable: true)
        #expect(document.environment.shell == "/bin/sh")
        #expect(document.entries.count == 1)
        #expect(document.entries[0].task.id == id)
        #expect(document.entries[0].task.schedule.preset == .daily)
        #expect(document.entries[0].task.schedule.hour == 3)
        #expect(document.entries[0].task.command == "/usr/bin/backup")
        #expect(document.rendered().contains("# terminator:\(id.uuidString)"))
        #expect(document.entries[0].task.name == "")
        #expect(document.rendered().contains("15 3 * * * /usr/bin/backup"))
    }

    @Test func commentedLineIsDisabled() {
        let host = UUID()
        let document = CrontabDocument.parse(hostID: host, text: "#0 * * * * /bin/true\n", hash: "", writable: true)
        #expect(document.entries.count == 1)
        #expect(document.entries[0].task.enabled == false)
        #expect(document.entries[0].task.schedule.preset == .hourly)
    }

    @Test func markerKeepsTheName() {
        let host = UUID()
        let id = UUID()
        let text = """
        # terminator:\(id.uuidString) Nightly backup
        15 3 * * * /usr/bin/backup
        """
        let document = CrontabDocument.parse(hostID: host, text: text, hash: "", writable: true)
        #expect(document.entries[0].task.name == "Nightly backup")
        #expect(document.rendered().contains("# terminator:\(id.uuidString) Nightly backup"))
    }
}
