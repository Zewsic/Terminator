import Foundation
import TerminatorCore

enum HistoryChangeKind: String, Equatable, Sendable {
    case added
    case removed
    case changed
}

struct HistoryFieldChange: Equatable, Identifiable, Sendable {
    var key: String
    var label: String
    var kind: HistoryChangeKind
    var before: String?
    var after: String?
    var isHidden: Bool

    var id: String { key }
}

struct HistoryEventDetail: Equatable {
    var name: String
    var symbol: String
    var changes: [HistoryFieldChange]
    var touchesPassword: Bool
}

enum HistoryEventSummary {
    static func detail(for entry: HistoryEntry) -> HistoryEventDetail {
        let before = object(from: entry.beforeSnapshot)
        let after = object(from: entry.afterSnapshot)
        let name = name(in: after) ?? name(in: before) ?? entry.title
        let keys = changedKeys(before: before, after: after)
        return HistoryEventDetail(
            name: name,
            symbol: symbol(for: entry.entity),
            changes: keys.map { change(for: $0, before: before, after: after) },
            touchesPassword: touchesPassword(before: before, after: after, changed: keys)
        )
    }

    static func symbol(for entity: HistoryEntity) -> String {
        switch entity {
        case .host: "server.rack"
        case .tunnel: "arrow.left.arrow.right"
        case .credential: "key"
        case .identity: "person"
        case .snippet: "curlybraces"
        }
    }

    private static func object(from data: Data?) -> [String: Any] {
        guard let data, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    private static func name(in object: [String: Any]) -> String? {
        for key in ["displayName", "name", "label"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func changedKeys(before: [String: Any], after: [String: Any]) -> [String] {
        Set(before.keys).union(after.keys)
            .filter { !["id", "createdAt", "updatedAt"].contains($0) }
            .filter { !valuesEqual(before[$0], after[$0]) }
            .sorted()
    }

    private static func change(for key: String, before: [String: Any], after: [String: Any]) -> HistoryFieldChange {
        let previous = before[key]
        let next = after[key]
        let hidden = isSensitive(key) || jsonContainsPassword(previous) || jsonContainsPassword(next)
        let kind: HistoryChangeKind
        if previous == nil || previous is NSNull { kind = .added }
        else if next == nil || next is NSNull { kind = .removed }
        else { kind = .changed }
        return HistoryFieldChange(
            key: key,
            label: label(key),
            kind: kind,
            before: hidden ? nil : display(previous, key: key),
            after: hidden ? nil : display(next, key: key),
            isHidden: hidden
        )
    }

    private static func touchesPassword(before: [String: Any], after: [String: Any], changed: [String]) -> Bool {
        changed.contains { key in
            isSensitive(key) || jsonContainsPassword(before[key]) || jsonContainsPassword(after[key])
        }
    }

    private static func isSensitive(_ key: String) -> Bool {
        let name = key.lowercased()
        return name.contains("password") || name.contains("secret") || name.contains("passphrase")
            || name.contains("privatekey") || name.contains("token")
    }

    private static func jsonContainsPassword(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.localizedCaseInsensitiveContains("\"password")
            || text.localizedCaseInsensitiveContains("passphrase")
            || text.localizedCaseInsensitiveContains("privatekey")
    }

    private static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (lhs?, rhs?):
            guard JSONSerialization.isValidJSONObject([lhs]), JSONSerialization.isValidJSONObject([rhs]),
                  let left = try? JSONSerialization.data(withJSONObject: [lhs]),
                  let right = try? JSONSerialization.data(withJSONObject: [rhs]) else { return false }
            return left == right
        }
    }

    private static func display(_ value: Any?, key: String) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return clip(text) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            if key.hasSuffix("At") { return Date(timeIntervalSinceReferenceDate: number.doubleValue).formatted() }
            return number.stringValue
        }
        if let items = value as? [String] { return clip(items.joined(separator: ", ")) }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return clip(text)
    }

    private static func clip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 280 else { return trimmed }
        return String(trimmed.prefix(280)) + "…"
    }

    private static func label(_ key: String) -> String {
        switch key {
        case "displayName", "name", "label": FeatureL10n.text(.logsFieldName)
        case "hostname": FeatureL10n.text(.logsFieldAddress)
        case "port": FeatureL10n.text(.logsFieldPort)
        case "notes": FeatureL10n.text(.logsFieldNotes)
        case "group": FeatureL10n.text(.logsFieldGroup)
        case "tags": FeatureL10n.text(.logsFieldTags)
        case "deletedAt": FeatureL10n.text(.logsFieldArchived)
        case "script", "body": FeatureL10n.text(.logsFieldScript)
        case "authentication", "authenticationMethods", "authenticationMethodsData": FeatureL10n.text(.logsFieldAuthentication)
        default:
            if isSensitive(key) {
                FeatureL10n.text(.logsFieldPassword)
            } else {
                key
            }
        }
    }
}
