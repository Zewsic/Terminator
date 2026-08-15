import Foundation
import Testing
@testable import TerminatorFeatures

@Suite("Authentication methods draft")
struct AuthenticationMethodsDraftTests {
    @Test("Access keys are unique and move only among access-key positions")
    func accessKeyMutation() {
        let first = UUID()
        let second = UUID()
        var draft = HostDraft()
        draft.authenticationMethods = [
            IdentityDraftMethod(kind: .password(existingSecretID: nil)),
            IdentityDraftMethod(kind: .accessKey(first)),
            IdentityDraftMethod(kind: .accessKey(second)),
        ]

        draft.addAccessKey(first)
        #expect(draft.authenticationMethods.count == 3)

        draft.moveAccessKey(at: 2, by: -1)
        guard case .accessKey(let moved) = draft.authenticationMethods[1].kind else {
            Issue.record("Expected an access key")
            return
        }
        #expect(moved == second)

        draft.removeAuthenticationMethod(at: 1)
        #expect(draft.authenticationMethods.count == 2)
    }
}
