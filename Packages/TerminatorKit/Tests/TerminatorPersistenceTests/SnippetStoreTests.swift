import Foundation
import Testing
import TerminatorCore
import TerminatorPersistence

@Test func snippetArchiveHidesTheRecordAndImportKeepsTheSameID() async throws {
    let container = try TerminatorSchema.makeContainer(inMemory: true)
    let store = TerminatorStore(modelContainer: container)
    let snippet = SnippetProfile(name: "Uptime", script: "uptime", group: "Ops", tags: ["health"], notes: "quick check")
    try await store.saveSnippet(snippet)
    try await store.deleteSnippet(id: snippet.id)
    let active = try await store.listSnippets(includeDeleted: false)
    #expect(active.isEmpty)
    let archived = try await store.listSnippets(includeDeleted: true)
    #expect(archived.count == 1)

    var imported = SnippetProfile(name: "Uptime", script: "uptime -p", externalID: "termius|1")
    try await store.importSnippet(imported)
    imported.script = "uptime -s"
    try await store.importSnippet(imported)
    let stored = try await store.listSnippets(includeDeleted: true).filter { $0.externalID == "termius|1" }
    #expect(stored.count == 1)
    #expect(stored[0].script == "uptime -s")
}

@Test func savingASnippetUpdatesHostStartCommandsThatLinkIt() async throws {
    let container = try TerminatorSchema.makeContainer(inMemory: true)
    let store = TerminatorStore(modelContainer: container)
    let snippet = SnippetProfile(name: "Enter", script: "cd /opt", notes: "")
    try await store.saveSnippet(snippet)
    let host = HostProfile(
        displayName: "App",
        hostname: "app.internal",
        username: "deploy",
        connectCommandSegments: [
            ConnectCommandSegment(text: "echo start\n"),
            ConnectCommandSegment(snippetID: snippet.id),
        ]
    )
    try await store.saveHost(host)
    let saved = try await store.host(id: host.id)
    #expect(saved?.connectCommands == "echo start\ncd /opt")

    var edited = snippet
    edited.script = "cd /srv"
    try await store.saveSnippet(edited)
    let refreshed = try await store.host(id: host.id)
    #expect(refreshed?.connectCommands == "echo start\ncd /srv")
    #expect(refreshed?.connectCommandSegments.count == 2)
}
