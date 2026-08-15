import Foundation
import SwiftData
import TerminatorCore

extension TerminatorStore {
    func validateReferences(for host: HostProfile) throws {
        switch host.authentication {
        case .identity(let id):
            guard let identity = try fetchIdentity(id: id)?.domain, !identity.isDeleted else {
                throw PersistenceError.referencedIdentityUnavailable
            }
        case .manual(_, let methods):
            try validateCredentialReferences(methods.compactMap(\.credentialID))
        }
    }

    func validateCredentialReferences(_ ids: [UUID]) throws {
        for id in ids {
            guard let credential = try fetchCredential(id: id)?.domain,
                  !credential.isDeleted,
                  credential.isSecretAvailable else {
                throw PersistenceError.referencedCredentialUnavailable
            }
        }
    }

    func credentialReferenceCount(id: UUID) throws -> Int {
        let hosts = try modelContext.fetch(FetchDescriptor<HostRecord>()).map(\.domain)
        let identities = try modelContext.fetch(FetchDescriptor<IdentityRecord>()).map(\.domain)
        return hosts.count { !$0.isDeleted && $0.authentication.credentialIDs.contains(id) }
            + identities.count { !$0.isDeleted && $0.credentialIDs.contains(id) }
    }

    func identityReferenceCount(id: UUID) throws -> Int {
        try modelContext.fetch(FetchDescriptor<HostRecord>()).map(\.domain)
            .count { !$0.isDeleted && $0.authentication.identityID == id }
    }

}
