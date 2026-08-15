import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
    func migrateLegacyPasswordMethods(_ host: HostProfile) throws -> HostProfile {
        guard case .manual(let username, let methods) = host.authentication else { return host }
        var copy = host
        copy.authentication = .manual(
            username: username,
            authenticationMethods: try methods.map(migrateLegacyPasswordMethod)
        )
        return copy
    }

    func migrateLegacyPasswordMethods(_ identity: IdentityProfile) throws -> IdentityProfile {
        var copy = identity
        copy.authenticationMethods = try identity.authenticationMethods.map(migrateLegacyPasswordMethod)
        return copy
    }

    func migrateLegacyPasswordMethod(_ method: AuthenticationMethod) throws -> AuthenticationMethod {
        guard case .accessKey(let id) = method,
              let credential = try fetchCredential(id: id)?.domain,
              credential.kind == .password else { return method }
        return .password(secretID: credential.secretID)
    }

}
