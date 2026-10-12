import Foundation
import TerminatorCore

enum HostListSort: String {
    case name
    case connected
}

@MainActor
@Observable
final class HostListPreferences {
    static let shared = HostListPreferences()

    private let defaults: UserDefaults
    private let sortKey = "hosts.sort"
    private let groupsKey = "hosts.grouped"
    private let connectedKey = "hosts.lastConnected"
    var sort: HostListSort {
        didSet { defaults.set(sort.rawValue, forKey: sortKey) }
    }
    var groupsEnabled: Bool {
        didSet { defaults.set(groupsEnabled, forKey: groupsKey) }
    }
    private var lastConnected: [String: TimeInterval]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sort = HostListSort(rawValue: defaults.string(forKey: sortKey) ?? "") ?? .name
        groupsEnabled = defaults.object(forKey: groupsKey) as? Bool ?? true
        lastConnected = defaults.dictionary(forKey: connectedKey) as? [String: TimeInterval] ?? [:]
    }

    func noteConnected(_ id: UUID) {
        lastConnected[id.uuidString] = Date().timeIntervalSince1970
        defaults.set(lastConnected, forKey: connectedKey)
    }

    func sorted(_ hosts: [HostProfile], logs: [SessionLogMetadata]) -> [HostProfile] {
        switch sort {
        case .name:
            return hosts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .connected:
            return hosts.sorted { lhs, rhs in
                let left = connectedDate(lhs.id, logs: logs)
                let right = connectedDate(rhs.id, logs: logs)
                switch (left, right) {
                case let (left?, right?) where left != right:
                    return left > right
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            }
        }
    }

    private func connectedDate(_ id: UUID, logs: [SessionLogMetadata]) -> Date? {
        let stored = lastConnected[id.uuidString].map(Date.init(timeIntervalSince1970:))
        let logged = logs.filter { $0.hostID == id }.map(\.startedAt).max()
        return [stored, logged].compactMap { $0 }.max()
    }
}
