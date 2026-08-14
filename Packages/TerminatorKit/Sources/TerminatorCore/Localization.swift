import Foundation

/// Internal localization gateway for user-facing Core strings.
public enum TerminatorCoreLocalization {
    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = String(localized: .init(key), bundle: .module)
        return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
    }
}
