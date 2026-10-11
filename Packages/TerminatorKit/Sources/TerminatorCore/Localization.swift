import Foundation

public enum CoreString: String, CaseIterable, Sendable {
    case credentialKindPassword = "credential.kind.password"
    case credentialKindAccessKey = "credential.kind.accessKey"
    case credentialKindLegacyPassphrase = "credential.kind.legacyPassphrase"
    case curveP256 = "curve.p256"
    case curveP384 = "curve.p384"
    case curveP521 = "curve.p521"
    case algorithmEd25519 = "algorithm.ed25519"
    case algorithmEcdsa = "algorithm.ecdsa"
    case algorithmRsa = "algorithm.rsa"
    case backendSoftware = "backend.software"
    case backendSecureEnclave = "backend.secureEnclave"
    case passphraseNone = "passphrase.none"
    case passphrasePromptEveryConnection = "passphrase.promptEveryConnection"
    case passphraseSaved = "passphrase.saved"
    case compatibilityLegacyRSA1024 = "compatibility.legacyRSA1024"
    case compatibilityNeedsUpgrade = "compatibility.needsUpgrade"
    case errorCredentialMissingLabel = "error.credential.missingLabel"
    case errorCredentialMissingSecret = "error.credential.missingSecret"
    case errorCredentialMissingAccessKeyMetadata = "error.credential.missingAccessKeyMetadata"
    case errorCredentialUnexpectedAccessKeyMetadata = "error.credential.unexpectedAccessKeyMetadata"
    case errorCredentialMissingPublicKey = "error.credential.missingPublicKey"
    case errorCredentialMissingFingerprint = "error.credential.missingFingerprint"
    case errorCredentialInvalidSecureEnclaveAlgorithm = "error.credential.invalidSecureEnclaveAlgorithm"
    case errorCredentialInvalidSecureEnclavePassphrase = "error.credential.invalidSecureEnclavePassphrase"
    case errorCredentialInvalidRSAKeySize = "error.credential.invalidRSAKeySize"
    case errorCredentialDuplicateAuthenticationMethod = "error.credential.duplicateAuthenticationMethod"
    case errorCredentialReferencedCredentialUnavailable = "error.credential.referencedCredentialUnavailable"
    case errorHostMissingDisplayName = "error.host.missingDisplayName"
    case errorHostMissingHostname = "error.host.missingHostname"
    case errorHostMissingUsername = "error.host.missingUsername"
    case errorHostInvalidPort = "error.host.invalidPort"
    case errorHostDuplicateAuthenticationMethod = "error.host.duplicateAuthenticationMethod"
    case errorHostReferencedIdentityUnavailable = "error.host.referencedIdentityUnavailable"
    case errorHostReferencedCredentialUnavailable = "error.host.referencedCredentialUnavailable"
    case errorIdentityMissingName = "error.identity.missingName"
    case errorIdentityMissingUsername = "error.identity.missingUsername"
    case errorIdentityMissingAuthenticationMethod = "error.identity.missingAuthenticationMethod"
    case errorIdentityDuplicateAuthenticationMethod = "error.identity.duplicateAuthenticationMethod"
    case errorIdentityMultiplePasswords = "error.identity.multiplePasswords"
    case errorIdentityInUse = "error.identity.inUse"
    case errorAccessKeyUnsupportedFormat = "error.accessKey.unsupportedFormat"
    case errorAccessKeyEncryptedLegacyFormatUnsupported = "error.accessKey.encryptedLegacyFormatUnsupported"
    case errorAccessKeyInvalidPrivateKey = "error.accessKey.invalidPrivateKey"
    case errorAccessKeyInvalidPassphrase = "error.accessKey.invalidPassphrase"
    case errorAccessKeyPublicKeyMismatch = "error.accessKey.publicKeyMismatch"
    case errorAccessKeyInvalidRSAKeySize = "error.accessKey.invalidRSAKeySize"
    case errorAccessKeySecureEnclaveUnavailable = "error.accessKey.secureEnclaveUnavailable"
    case errorAccessKeySecureEnclaveKeyIsNotExportable = "error.accessKey.secureEnclaveKeyIsNotExportable"
    case errorAccessKeyAuthorizationCancelled = "error.accessKey.authorizationCancelled"
    case errorAccessKeyPassphraseRequired = "error.accessKey.passphraseRequired"
    case errorOpenSSHAliasConflict = "error.openSSH.aliasConflict"
    case errorOpenSSHFileConflict = "error.openSSH.fileConflict"
    case errorOpenSSHInvalidDestination = "error.openSSH.invalidDestination"
    case terminalTerminal = "terminal.terminal"
    case terminalOther = "terminal.other"
    case errorConnectionServiceUnavailable = "error.connection.serviceUnavailable"
    case errorConnectionPromptTimedOut = "error.connection.promptTimedOut"
    case errorAccessCLIDisabled = "error.access.cliDisabled"
    case errorAccessMCPDisabled = "error.access.mcpDisabled"
    case errorStoreHostNotFound = "error.store.hostNotFound"
    case errorStoreCredentialNotFound = "error.store.credentialNotFound"
    case errorStoreIdentityNotFound = "error.store.identityNotFound"
    case errorStoreHistoryEntryNotFound = "error.store.historyEntryNotFound"
    case errorStoreUnsupportedHistorySchema = "error.store.unsupportedHistorySchema"
    case errorStoreSecretPurgeIsIrreversible = "error.store.secretPurgeIsIrreversible"
    case errorStoreCredentialInUse = "error.store.credentialInUse"
    case errorStoreIdentityInUse = "error.store.identityInUse"
    case errorStoreReferencedCredentialUnavailable = "error.store.referencedCredentialUnavailable"
    case errorStoreReferencedIdentityUnavailable = "error.store.referencedIdentityUnavailable"
    case hostUsernameIdentity = "host.username.identity"
    case commonUnknown = "common.unknown"
    case legacykeyUpgradeRequired = "legacyKey.upgradeRequired"
    case historyTitle = "history.title"
    case historyEntityHost = "history.entity.host"
    case historyEntityCredential = "history.entity.credential"
    case historyEntityIdentity = "history.entity.identity"
    case historyEntityTunnel = "history.entity.tunnel"
    case tunnelKindLocal = "tunnel.kind.local"
    case tunnelKindRemote = "tunnel.kind.remote"
    case tunnelKindDynamic = "tunnel.kind.dynamic"
    case tunnelEndpointThisMac = "tunnel.endpoint.thisMac"
    case errorTunnelMissingDisplayName = "error.tunnel.missingDisplayName"
    case errorTunnelInvalidPort = "error.tunnel.invalidPort"
    case errorTunnelDestinationIsLocal = "error.tunnel.destinationIsLocal"
    case errorTunnelMissingHostname = "error.tunnel.missingHostname"
    case errorTunnelDynamicRequiresThisMac = "error.tunnel.dynamicRequiresThisMac"
    case errorStoreTunnelNotFound = "error.store.tunnelNotFound"
    case historyOperationCreated = "history.operation.created"
    case historyOperationUpdated = "history.operation.updated"
    case historyOperationDeleted = "history.operation.deleted"
    case historyOperationRestored = "history.operation.restored"
    case historyOperationPurged = "history.operation.purged"
}

public enum TerminatorCoreLocalization {
    public static func text(_ key: CoreString, _ arguments: CVarArg...) -> String {
        text(key.rawValue, arguments)
    }

    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        text(key, locale: .current, arguments: arguments)
    }

    public static func text(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        text(key, locale: locale, arguments: arguments)
    }

    private static func text(_ key: String, locale: Locale = .current, arguments: [CVarArg]) -> String {
        let format = String(localized: .init(key), bundle: .module)
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }
}
