import Foundation
import SwiftData
import TerminatorCore

public enum PersistenceError: LocalizedError, Equatable, Sendable {
    case hostNotFound
    case credentialNotFound
    case identityNotFound
    case tunnelNotFound
    case snippetNotFound
    case historyEntryNotFound
    case unsupportedHistorySchema(Int)
    case secretPurgeIsIrreversible
    case credentialInUse
    case identityInUse
    case referencedCredentialUnavailable
    case referencedIdentityUnavailable

    public var errorDescription: String? {
        switch self {
        case .hostNotFound: TerminatorCoreLocalization.text("error.store.hostNotFound")
        case .credentialNotFound: TerminatorCoreLocalization.text("error.store.credentialNotFound")
        case .identityNotFound: TerminatorCoreLocalization.text("error.store.identityNotFound")
        case .tunnelNotFound: TerminatorCoreLocalization.text("error.store.tunnelNotFound")
        case .snippetNotFound: TerminatorCoreLocalization.text("error.store.snippetNotFound")
        case .historyEntryNotFound: TerminatorCoreLocalization.text("error.store.historyEntryNotFound")
        case .unsupportedHistorySchema(let version): TerminatorCoreLocalization.text("error.store.unsupportedHistorySchema", version)
        case .secretPurgeIsIrreversible: TerminatorCoreLocalization.text("error.store.secretPurgeIsIrreversible")
        case .credentialInUse: TerminatorCoreLocalization.text("error.store.credentialInUse")
        case .identityInUse: TerminatorCoreLocalization.text("error.store.identityInUse")
        case .referencedCredentialUnavailable: TerminatorCoreLocalization.text("error.store.referencedCredentialUnavailable")
        case .referencedIdentityUnavailable: TerminatorCoreLocalization.text("error.store.referencedIdentityUnavailable")
        }
    }
}

@ModelActor
public actor TerminatorStore: HostRepository, CredentialRepository, IdentityRepository, HistoryRepository, KnownHostRepository, SessionLogRepository, TunnelRepository, SnippetRepository {
    var encoder: JSONEncoder { JSONEncoder() }
    var decoder: JSONDecoder { JSONDecoder() }
}
