import Foundation
import TerminatorCore

public enum AccessKeyDraftMode: String, CaseIterable, Sendable {
    case importExisting
    case generateSoftware
    case generateSecureEnclave
}

public struct AccessKeyDraft: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var credentialID: UUID?
    public var label = ""
    public var mode: AccessKeyDraftMode = .generateSoftware
    public var generation: SoftwareKeyGeneration = .ed25519
    public var privateKey = ""
    public var publicKey = ""
    public var comment = ""
    public var passphrase = ""
    public var passphraseConfirmation = ""
    public var savePassphrase = false
    public var acceptLegacyRSA1024 = false
    public var requiresUnlock = false
    public var originalAlgorithm: SSHKeyAlgorithm?
    public var suggestedLabelContext: String?
    public var suggestedOrdinal: Int?
    public init() {}

    public var automaticLabel: String {
        let ordinal = suggestedOrdinal ?? 1
        let context = suggestedLabelContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return context.isEmpty
            ? FeatureL10n.text(.keyAutomaticLabel, ordinal)
            : FeatureL10n.text(.keyAutomaticLabelContext, ordinal, context)
    }
}

public enum AccessKeyImportPolicyError: LocalizedError, Equatable, Sendable {
    case legacyRSAConfirmationRequired

    public var errorDescription: String? {
        "RSA-1024 is obsolete and should be imported only for a known legacy server. Enable the compatibility confirmation to continue."
    }
}
