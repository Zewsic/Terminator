#if !APP_STORE
import CoreSpotlight
import Foundation
import TerminatorCore

/// Publishes non-secret host metadata. Spotlight opens the app through the
/// searchable-item activity, which is handled by `TerminatorApp`.
final class SpotlightHostIndexer: @unchecked Sendable {
    static let domainIdentifier = "pro.zewsic.terminator.host"
    static let itemPrefix = "host."

    func index(_ hosts: [HostProfile]) async {
        let items = hosts.map { host in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = host.displayName
            attributes.contentDescription = "SSH · \(host.hostname):\(host.port)"
            attributes.keywords = [host.displayName, host.hostname, host.group].compactMap { $0 }
            return CSSearchableItem(
                uniqueIdentifier: Self.itemPrefix + host.id.uuidString,
                domainIdentifier: Self.domainIdentifier,
                attributeSet: attributes
            )
        }

        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { _ in
                CSSearchableIndex.default().indexSearchableItems(items) { _ in
                    continuation.resume()
                }
            }
        }
    }

    func clear() async {
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { _ in
                continuation.resume()
            }
        }
    }

    func hostID(for searchableItemIdentifier: String) -> UUID? {
        guard searchableItemIdentifier.hasPrefix(Self.itemPrefix) else { return nil }
        return UUID(uuidString: String(searchableItemIdentifier.dropFirst(Self.itemPrefix.count)))
    }
}
#endif
