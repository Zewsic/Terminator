import Foundation
import TerminatorCore

public struct IdentityDraft: Identifiable, Equatable, Sendable {
    public var id: UUID?
    public var name: String
    public var username: String
    public var authenticationMethods: [IdentityDraftMethod]

    public init(identity: IdentityProfile? = nil) {
        id = identity?.id
        name = identity?.name ?? ""
        username = identity?.username ?? ""
        let methods: [IdentityDraftMethod] = identity?.authenticationMethods.map { method -> IdentityDraftMethod in
            switch method {
            case .password(let secretID):
                IdentityDraftMethod(kind: .password(existingSecretID: secretID))
            case .accessKey(let credentialID):
                IdentityDraftMethod(kind: .accessKey(credentialID))
            }
        } ?? []
        let password = methods.first { method in
            if case .password = method.kind { return true }
            return false
        } ?? IdentityDraftMethod(kind: .password(existingSecretID: nil))
        authenticationMethods = [password] + methods.filter { method in
            if case .accessKey = method.kind { return true }
            return false
        }
    }
}

public struct IdentityDraftMethod: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: IdentityDraftMethodKind
    public var password = ""
    public var passwordChanged = false

    public init(kind: IdentityDraftMethodKind) { self.kind = kind }
}

public enum IdentityDraftMethodKind: Equatable, Sendable {
    case password(existingSecretID: SecretID?)
    case accessKey(UUID)
}
