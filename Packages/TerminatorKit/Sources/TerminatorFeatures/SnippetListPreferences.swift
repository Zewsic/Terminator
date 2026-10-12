import Foundation
import TerminatorCore

enum SnippetListSort: String {
    case name
    case lastUsage
}

@MainActor
@Observable
final class SnippetListPreferences {
    static let shared = SnippetListPreferences()

    private let defaults: UserDefaults
    private let sortKey = "snippets.sort"
    private let groupsKey = "snippets.grouped"
    var sort: SnippetListSort {
        didSet { defaults.set(sort.rawValue, forKey: sortKey) }
    }
    var groupsEnabled: Bool {
        didSet { defaults.set(groupsEnabled, forKey: groupsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sort = SnippetListSort(rawValue: defaults.string(forKey: sortKey) ?? "") ?? .name
        groupsEnabled = defaults.object(forKey: groupsKey) as? Bool ?? true
    }

    func sorted(_ snippets: [SnippetProfile]) -> [SnippetProfile] {
        switch sort {
        case .name:
            return snippets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsage:
            return snippets.sorted { lhs, rhs in
                switch (lhs.lastUsedAt, rhs.lastUsedAt) {
                case let (left?, right?) where left != right:
                    return left > right
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
        }
    }
}
