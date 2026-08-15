import Foundation
import Testing
import TerminatorCore
@testable import TerminatorFeatures

@MainActor
@Suite("Connection prompt center")
struct ConnectionPromptCenterTests {
    @Test("Submitting a prompt resumes it exactly once")
    func submitOnce() async throws {
        let center = ConnectionPromptCenter()
        let host = HostProfile(displayName: "Host", hostname: "example.com", username: "")
        let task = Task { try await center.requestUsername(for: host) }
        await waitForRequest(center)

        center.submit(text: "deploy")
        center.submit(text: "ignored")

        #expect(try await task.value == "deploy")
        #expect(center.request == nil)
    }

    @Test("A replacement prompt cancels the previous continuation")
    func replacementCancelsPrevious() async throws {
        let center = ConnectionPromptCenter()
        let host = HostProfile(displayName: "Host", hostname: "example.com", username: "")
        let first = Task { try await center.requestUsername(for: host) }
        await waitForRequest(center)
        let firstID = center.request?.id
        let second = Task { try await center.requestPassword(for: host, username: "deploy") }
        await waitForRequest(center, differentFrom: firstID)
        center.submit(text: "secret")

        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == "secret")
    }

    @Test("Cancel clears the sheet request and resumes with cancellation")
    func cancel() async {
        let center = ConnectionPromptCenter()
        let host = HostProfile(displayName: "Host", hostname: "example.com", username: "")
        let task = Task { try await center.requestUsername(for: host) }
        await waitForRequest(center)

        center.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(center.request == nil)
    }

    private func waitForRequest(_ center: ConnectionPromptCenter, differentFrom id: UUID? = nil) async {
        for _ in 0..<100 {
            if let request = center.request, request.id != id { return }
            await Task.yield()
        }
        Issue.record("Prompt request was not published")
    }
}
