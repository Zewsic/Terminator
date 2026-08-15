import Foundation

public struct PresentedError: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let message: String

    public init(id: String, title: String, message: String) {
        self.id = id
        self.title = title
        self.message = message
    }

    public init(_ error: any Error) {
        let message = error.localizedDescription
        self.init(
            id: String(reflecting: type(of: error)) + ":" + message,
            title: FeatureL10n.text(.errorGenericTitle),
            message: message
        )
    }

    public init(id: String, message: String) {
        self.init(id: id, title: FeatureL10n.text(.errorGenericTitle), message: message)
    }
}
