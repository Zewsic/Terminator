import Foundation

enum SecurityString: String, CaseIterable, Sendable {
    case errorDuplicateSecret = "error.duplicateSecret"
    case errorSecretNotFound = "error.secretNotFound"
    case errorUnexpectedData = "error.unexpectedData"
    case errorAccessControlCreationFailed = "error.accessControlCreationFailed"
    case errorSecurityStatus = "error.securityStatus"
    case authenticationUnlockPassphrase = "authentication.unlockPassphrase"
}

enum SecurityL10n {
    static func text(_ key: SecurityString, _ arguments: CVarArg...) -> String {
        text(key.rawValue, arguments)
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        text(key, locale: .current, arguments: arguments)
    }

    static func text(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        text(key, locale: locale, arguments: arguments)
    }

    private static func text(_ key: String, locale: Locale = .current, arguments: [CVarArg]) -> String {
        let format = String(localized: .init(key), bundle: .module)
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }
}
