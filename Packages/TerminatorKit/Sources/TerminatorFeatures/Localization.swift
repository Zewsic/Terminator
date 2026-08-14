import Foundation

enum FeatureL10n {
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = String(localized: .init(key), bundle: .module)
        return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
    }
}
