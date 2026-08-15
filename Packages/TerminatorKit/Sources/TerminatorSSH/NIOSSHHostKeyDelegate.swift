import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOSSH
import TerminatorCore
import TerminatorSecurity

final class StrictHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: String
    private let repository: any KnownHostRepository
    private let prompting: any SSHConnectionPrompting

    init(endpoint: String, repository: any KnownHostRepository, prompting: any SSHConnectionPrompting) {
        self.endpoint = endpoint; self.repository = repository; self.prompting = prompting
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        Task {
            do {
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2, let blob = Data(base64Encoded: String(fields[1])) else {
                    throw SSHTransportError.hostKeyRejected
                }
                let fingerprint = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
                let presented = KnownHostKey(
                    endpoint: endpoint, algorithm: String(fields[0]), publicKey: blob, fingerprint: fingerprint
                )
                if let stored = try await repository.knownHost(endpoint: endpoint, algorithm: presented.algorithm) {
                    guard stored.publicKey == blob else {
                        if try await prompting.confirmChangedHost(previous: stored, presented: presented) {
                            var replacement = presented
                            replacement.id = stored.id; replacement.createdAt = stored.createdAt
                            try await repository.saveKnownHost(replacement)
                            validationCompletePromise.succeed(())
                        } else { validationCompletePromise.fail(SSHTransportError.hostKeyRejected) }
                        return
                    }
                    validationCompletePromise.succeed(())
                } else if try await prompting.trustNewHost(presented) {
                    try await repository.saveKnownHost(presented)
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(SSHTransportError.hostKeyRejected)
                }
            } catch { validationCompletePromise.fail(error) }
        }
    }
}
