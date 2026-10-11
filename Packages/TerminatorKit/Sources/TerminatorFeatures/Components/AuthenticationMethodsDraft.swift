import Foundation

enum AuthenticationMethodsDraft {
    static func addAccessKey(_ id: UUID, to methods: inout [IdentityDraftMethod]) {
        guard !methods.contains(where: {
            if case .accessKey(id) = $0.kind { return true }
            return false
        }) else { return }
        methods.append(IdentityDraftMethod(kind: .accessKey(id)))
    }

    static func moveAccessKey(at index: Int, by delta: Int, in methods: inout [IdentityDraftMethod]) {
        let accessKeyIndices = methods.indices.filter {
            if case .accessKey = methods[$0].kind { return true }
            return false
        }
        guard let position = accessKeyIndices.firstIndex(of: index) else { return }
        let destination = position + delta
        guard accessKeyIndices.indices.contains(destination) else { return }
        methods.swapAt(index, accessKeyIndices[destination])
    }

    static func reorderAccessKey(
        _ sourceID: UUID,
        to targetID: UUID,
        in methods: inout [IdentityDraftMethod]
    ) {
        guard sourceID != targetID else { return }
        let accessKeyIndices = methods.indices.filter {
            if case .accessKey = methods[$0].kind { return true }
            return false
        }
        var accessKeys = accessKeyIndices.map { methods[$0] }
        guard let sourcePosition = accessKeys.firstIndex(where: { method in
            if case .accessKey(sourceID) = method.kind { return true }
            return false
        }), let targetPosition = accessKeys.firstIndex(where: { method in
            if case .accessKey(targetID) = method.kind { return true }
            return false
        }) else { return }

        let moved = accessKeys.remove(at: sourcePosition)
        accessKeys.insert(moved, at: targetPosition)
        for (position, index) in accessKeyIndices.enumerated() {
            methods[index] = accessKeys[position]
        }
    }

    static func remove(at index: Int, from methods: inout [IdentityDraftMethod]) {
        guard methods.indices.contains(index) else { return }
        methods.remove(at: index)
    }
}

public extension HostDraft {
    mutating func addAccessKey(_ id: UUID) {
        AuthenticationMethodsDraft.addAccessKey(id, to: &authenticationMethods)
    }

    mutating func moveAccessKey(at index: Int, by delta: Int) {
        AuthenticationMethodsDraft.moveAccessKey(at: index, by: delta, in: &authenticationMethods)
    }

    mutating func reorderAccessKey(_ sourceID: UUID, to targetID: UUID) {
        AuthenticationMethodsDraft.reorderAccessKey(sourceID, to: targetID, in: &authenticationMethods)
    }

    mutating func removeAuthenticationMethod(at index: Int) {
        AuthenticationMethodsDraft.remove(at: index, from: &authenticationMethods)
    }
}

public extension IdentityDraft {
    mutating func addAccessKey(_ id: UUID) {
        AuthenticationMethodsDraft.addAccessKey(id, to: &authenticationMethods)
    }

    mutating func moveAccessKey(at index: Int, by delta: Int) {
        AuthenticationMethodsDraft.moveAccessKey(at: index, by: delta, in: &authenticationMethods)
    }

    mutating func reorderAccessKey(_ sourceID: UUID, to targetID: UUID) {
        AuthenticationMethodsDraft.reorderAccessKey(sourceID, to: targetID, in: &authenticationMethods)
    }

    mutating func removeAuthenticationMethod(at index: Int) {
        AuthenticationMethodsDraft.remove(at: index, from: &authenticationMethods)
    }
}
