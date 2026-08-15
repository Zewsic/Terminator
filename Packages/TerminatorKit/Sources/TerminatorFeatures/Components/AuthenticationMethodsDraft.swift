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

    mutating func removeAuthenticationMethod(at index: Int) {
        AuthenticationMethodsDraft.remove(at: index, from: &authenticationMethods)
    }
}
