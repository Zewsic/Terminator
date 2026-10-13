import Foundation
import Observation

@MainActor
@Observable
public final class DevelopmentPreferences {
    public static let shared = DevelopmentPreferences()

    private let enabledKey = "development.enabled"
    private let restrictionsKey = "development.restrictionsRemoved"
    private let defaults: UserDefaults

    public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: enabledKey) }
    }

    public var restrictionsRemoved: Bool {
        didSet { defaults.set(restrictionsRemoved, forKey: restrictionsKey) }
    }

    /// Unavailable programs can be selected so their forms can be reviewed.
    public var previewsUnavailableFeatures: Bool { enabled && restrictionsRemoved }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: enabledKey)
        restrictionsRemoved = defaults.bool(forKey: restrictionsKey)
    }
}
