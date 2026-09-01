import Foundation

enum AppString: String, CaseIterable, Sendable {
    case settingsEdition = "settings.edition"
    case settingsDistribution = "settings.distribution"
    case settingsDistributionAppStore = "settings.distribution.appStore"
    case settingsDistributionDirect = "settings.distribution.direct"
    case settingsLocalShell = "settings.localShell"
    case settingsLocalShellFuture = "settings.localShell.future"
    case settingsLocalShellUnavailable = "settings.localShell.unavailable"
    case settingsExternalFiles = "settings.externalFiles"
    case settingsExternalFilesUserControlled = "settings.externalFiles.userControlled"
    case settingsExternalFilesSandboxed = "settings.externalFiles.sandboxed"
    case settingsStorage = "settings.storage"
    case settingsCatalog = "settings.catalog"
    case settingsCatalogValue = "settings.catalog.value"
    case settingsSecrets = "settings.secrets"
    case settingsSecretsValue = "settings.secrets.value"
    case settingsCloudSync = "settings.cloudSync"
    case settingsCloudSyncDisabled = "settings.cloudSync.disabled"
    case settingsRetention = "settings.retention"
    case settingsRetentionNote = "settings.retention.note"
    case settingsLicensing = "settings.licensing"
    case settingsCommercialLicensing = "settings.commercialLicensing"
    case settingsLicense = "settings.license"
    case settingsTitle = "settings.title"
    case exportWarningTitle = "export.warning.title"
    case exportWarningMessage = "export.warning.message"
    case actionContinue = "action.continue"
    case actionCancel = "action.cancel"
    case errorAttachNotEmbedded = "error.attachNotEmbedded"
    case errorTerminalNotInstalled = "error.terminal.notInstalled"
    case errorTerminalInvalidURL = "error.terminal.invalidURL"
    case errorTerminalOpenFailed = "error.terminal.openFailed"
    case opensshImportMissingUser = "openSSH.import.missingUser"
    case opensshImportRecursiveInclude = "openSSH.import.recursiveInclude"
    case openSSHEncryptedLegacyUnsupported = "openSSH.encryptedLegacy.unsupported"
    case demoEndpointProduction = "demo.endpoint.production"
    case demoEndpointHomeLab = "demo.endpoint.homeLab"
    case settingsPinnedAndActiveSessionsAreNeverRemoved = "settings.pinnedAndActiveSessionsAreNeverRemoved"
    case settingsPolyformNoncommercial100 = "settings.polyformNoncommercial100"
    case settingsSettings = "settings.settings"
    case settingsGeneral = "settings.general"
    case settingsAccess = "settings.access"
    case settingsAccessCLI = "settings.access.cli"
    case settingsAccessCLICaption = "settings.access.cli.caption"
    case settingsAccessMCP = "settings.access.mcp"
    case settingsAccessMCPCaption = "settings.access.mcp.caption"
    case settingsInterface = "settings.interface"
    case settingsRestoreHiddenBanners = "settings.restoreHiddenBanners"
    case settingsRestoreHiddenBannersCaption = "settings.restoreHiddenBanners.caption"
}

enum AppL10n {
    nonisolated static func text(_ key: AppString, _ arguments: CVarArg...) -> String {
        text(key.rawValue, arguments)
    }

    nonisolated static func text(_ key: String, _ arguments: CVarArg...) -> String {
        text(key, arguments)
    }

    private nonisolated static func text(_ key: String, _ arguments: [CVarArg]) -> String {
        let format = String(localized: .init(key), bundle: .main)
        return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
    }
}
