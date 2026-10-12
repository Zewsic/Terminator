import Foundation
import Testing
import TerminatorCore

@Test func connectCommandRendersLinkedSnippets() {
    let snippet = UUID()
    let segments = [
        ConnectCommandSegment(text: "cd /srv\n"),
        ConnectCommandSegment(snippetID: snippet),
        ConnectCommandSegment(text: "\nls"),
    ]
    let rendered = ConnectCommandScript.render(segments, scripts: [snippet: "source ./env"])
    #expect(rendered == "cd /srv\nsource ./env\nls")
    #expect(ConnectCommandScript.render(segments, scripts: [:]) == "cd /srv\n\nls")
}

@Test func emptyTextSegmentsAreDropped() {
    let kept = ConnectCommandScript.stored([
        ConnectCommandSegment(text: ""),
        ConnectCommandSegment(text: "echo hi"),
        ConnectCommandSegment(snippetID: UUID()),
    ])
    #expect(kept.count == 2)
}

@Test func hostSearchMatchesGroupTagAndNotes() {
    let host = HostProfile(
        displayName: "Edge",
        hostname: "edge.example",
        username: "root",
        group: "Production",
        tags: ["web"],
        notes: "behind the proxy"
    )
    let other = HostProfile(displayName: "Database", hostname: "db.internal", username: "postgres")
    #expect(HostCatalogSearch.matches(host, terms: ["production"], identities: []))
    #expect(HostCatalogSearch.matches(host, terms: ["web"], identities: []))
    #expect(HostCatalogSearch.matches(host, terms: ["proxy"], identities: []))
    #expect(!HostCatalogSearch.matches(other, terms: ["proxy"], identities: []))
}
