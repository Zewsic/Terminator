import Foundation
import TerminatorCore

public struct HostDraft: Identifiable, Equatable, Sendable {
    public var id: UUID?
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var usesIdentity: Bool
    public var identityID: UUID?
    public var username: String
    public var authenticationMethods: [IdentityDraftMethod]
    public var group: String
    public var tagsText: String
    public var notes: String
    public var sessionPersistence: SessionPersistence
    public var remoteShell: RemoteShell
    public var connectCommands: String
    public var connectCommandSegments: [ConnectCommandSegment]
    public var alwaysConnected: Bool
    public var dockerCommandPrefix: String

    public init(host: HostProfile? = nil) {
        id = host?.id
        displayName = host?.displayName ?? ""
        hostname = host?.hostname ?? ""
        port = host?.port ?? 22
        usesIdentity = host?.authentication.identityID != nil
        identityID = host?.authentication.identityID
        username = host?.authentication.manualUsername ?? ""
        let methods: [IdentityDraftMethod] = host?.authentication.authenticationMethods.map { method in
            switch method {
            case .password(let secretID):
                return IdentityDraftMethod(kind: .password(existingSecretID: secretID))
            case .accessKey(let credentialID):
                return IdentityDraftMethod(kind: .accessKey(credentialID))
            }
        } ?? []
        let password = methods.first { method in
            if case .password = method.kind { return true }
            return false
        } ?? IdentityDraftMethod(kind: .password(existingSecretID: nil))
        authenticationMethods = [password] + methods.filter { method in
            if case .accessKey = method.kind { return true }
            return false
        }
        group = host?.group ?? ""
        tagsText = host?.tags.joined(separator: ", ") ?? ""
        notes = host?.notes ?? ""
        sessionPersistence = host?.sessionPersistence ?? .none
        remoteShell = host?.remoteShell ?? .login
        connectCommands = host?.connectCommands ?? ""
        if let segments = host?.connectCommandSegments, !segments.isEmpty {
            connectCommandSegments = segments
        } else if let commands = host?.connectCommands, !commands.isEmpty {
            connectCommandSegments = [ConnectCommandSegment(text: commands)]
        } else {
            connectCommandSegments = [ConnectCommandSegment()]
        }
        alwaysConnected = host?.alwaysConnected ?? false
        dockerCommandPrefix = host?.dockerCommandPrefix ?? DockerCommandPrefix.fallback
    }

    public var tags: [String] { tagsText.split(separator: ",").map(String.init) }
}

extension String {
    var normalizedSSHEndpoint: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
