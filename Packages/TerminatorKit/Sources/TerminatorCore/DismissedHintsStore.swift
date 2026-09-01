import Foundation
import Observation

@MainActor
@Observable
public final class DismissedHintsStore {
    public static let shared = DismissedHintsStore()

    public enum Hint: String, CaseIterable, Sendable {
        case hostsImportBanner
        case credentialsImportBanner
        case tunnelsImportBanner
    }

    private static let prefix = "dismissedHint."
    private static let legacyHostsImportBannerKey = "hosts.importBannerDismissed"

    private let defaults: UserDefaults
    public private(set) var dismissedIDs: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var ids = Set(
            Hint.allCases
                .map(\.rawValue)
                .filter { defaults.bool(forKey: Self.prefix + $0) }
        )
        if defaults.bool(forKey: Self.legacyHostsImportBannerKey) {
            ids.insert(Hint.hostsImportBanner.rawValue)
            defaults.set(true, forKey: Self.prefix + Hint.hostsImportBanner.rawValue)
            defaults.removeObject(forKey: Self.legacyHostsImportBannerKey)
        }
        dismissedIDs = ids
    }

    public var hasDismissedHints: Bool { !dismissedIDs.isEmpty }

    public func isDismissed(_ hint: Hint) -> Bool {
        dismissedIDs.contains(hint.rawValue)
    }

    public func dismiss(_ hint: Hint) {
        guard dismissedIDs.insert(hint.rawValue).inserted else { return }
        defaults.set(true, forKey: Self.prefix + hint.rawValue)
    }

    public func restoreAll() {
        for hint in Hint.allCases {
            defaults.removeObject(forKey: Self.prefix + hint.rawValue)
        }
        defaults.removeObject(forKey: Self.legacyHostsImportBannerKey)
        dismissedIDs = []
    }
}
