import Foundation

public enum HostCatalogSearch {
    public static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func matches(_ host: HostProfile, terms: [String], identities: [IdentityProfile]) -> Bool {
        guard !terms.isEmpty else { return true }
        let identity = host.authentication.identityID.flatMap { id in identities.first { $0.id == id } }
        let username = host.authentication.manualUsername ?? identity?.username ?? ""
        var values = [host.displayName, host.hostname, username, host.group ?? "", host.notes]
        values.append(contentsOf: host.tags)
        if let identity {
            values.append(identity.name)
            values.append(identity.username)
        }
        return terms.allSatisfy { term in
            values.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
}
