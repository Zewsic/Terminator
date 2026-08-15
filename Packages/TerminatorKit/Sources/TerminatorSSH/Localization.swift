import Foundation

enum SSHString: String, CaseIterable, Sendable {
    case errorAuthenticationTimedOut = "error.authenticationTimedOut"
    case errorAuthenticationFailed = "error.authenticationFailed"
    case errorHostKeyRejected = "error.hostKeyRejected"
    case errorUnsupportedRSA = "error.unsupportedRSA"
    case errorSessionUnavailable = "error.sessionUnavailable"
    case errorInvalidLogFormat = "error.invalidLogFormat"
    case errorMissingLog = "error.missingLog"
    case errorExpiredOrInvalidToken = "error.expiredOrInvalidToken"
    case errorProtocolError = "error.protocolError"
    case authenticationSecureEnclaveRequired = "authentication.secureEnclave.required"
    case sessionReconnected = "session.reconnected"
}

enum SSHL10n {
    static func text(_ key: SSHString, _ arguments: CVarArg...) -> String {
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
