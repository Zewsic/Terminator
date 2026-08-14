import Foundation

enum AppL10n {
    nonisolated static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = String(localized: .init(key), bundle: .main)
        return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
    }
}
