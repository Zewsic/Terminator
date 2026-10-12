import Foundation
import Testing
import TerminatorCore
@testable import TerminatorFeatures

@Test func historySummaryNamesTheRecordAndListsChangedFields() throws {
    let before = HostProfile(displayName: "Old", hostname: "one.example", username: "root")
    var after = before
    after.displayName = "New"
    after.hostname = "two.example"
    let entry = HistoryEntry(
        entity: .host,
        entityID: before.id,
        operation: .updated,
        beforeSnapshot: try JSONEncoder().encode(before),
        afterSnapshot: try JSONEncoder().encode(after)
    )
    let detail = HistoryEventSummary.detail(for: entry)
    #expect(detail.name == "New")
    #expect(detail.symbol == "server.rack")
    let name = try #require(detail.changes.first { $0.key == "displayName" })
    #expect(name.kind == .changed)
    #expect(name.before == "Old")
    #expect(name.after == "New")
    #expect(detail.changes.contains { $0.key == "hostname" && $0.after == "two.example" })
    #expect(!detail.touchesPassword)
}
