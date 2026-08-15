import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOSSH
import TerminatorCore
import TerminatorSecurity

enum AuthOffer: @unchecked Sendable {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

final class OrderedAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let onExhausted: @Sendable (NIOSSHAvailableUserAuthenticationMethods) -> Void
    private let lock = NSLock()
    private var offers: [AuthOffer]

    init(
        username: String,
        offers: [AuthOffer],
        onExhausted: @escaping @Sendable (NIOSSHAvailableUserAuthenticationMethods) -> Void
    ) {
        self.username = username
        self.offers = offers
        self.onExhausted = onExhausted
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        defer { lock.unlock() }
        while !offers.isEmpty {
            let offer = offers.removeFirst()
            switch offer {
            case .password(let password) where availableMethods.contains(.password):
                nextChallengePromise.succeed(.init(
                    username: username, serviceName: "ssh-connection", offer: .password(.init(password: password))
                ))
                return
            case .privateKey(let key) where availableMethods.contains(.publicKey):
                nextChallengePromise.succeed(.init(
                    username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))
                ))
                return
            default: continue
            }
        }
        let error = SSHTransportError.authenticationRejected(
            availableMethods: availableMethods.terminatorDisplayNames
        )
        onExhausted(availableMethods)
        nextChallengePromise.fail(error)
    }
}

extension NIOSSHAvailableUserAuthenticationMethods {
    var terminatorDisplayNames: [String] {
        var result: [String] = []
        if contains(.password) { result.append("password") }
        if contains(.publicKey) { result.append("public key") }
        if contains(.hostBased) { result.append("host-based authentication") }
        return result
    }
}

final class AuthenticationResultBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    let futureResult: EventLoopFuture<Void>
    private let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var completed = false

    init(eventLoop: EventLoop) {
        promise = eventLoop.makePromise(of: Void.self)
        futureResult = promise.futureResult
    }

    func fail(_ error: Error) {
        complete { promise.fail(error) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete { promise.succeed(()) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(SSHTransportError.authenticationFailed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.fireErrorCaught(error)
    }

    func complete(_ body: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        body()
    }
}
