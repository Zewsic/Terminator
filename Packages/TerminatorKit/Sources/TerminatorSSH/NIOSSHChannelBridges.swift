import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOSSH
import TerminatorCore
import TerminatorSecurity

final class TransportCloseBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let onClose: @Sendable (Error?) -> Void
    init(onClose: @escaping @Sendable (Error?) -> Void) { self.onClose = onClose }
    func channelInactive(context: ChannelHandlerContext) { onClose(nil); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { onClose(error); context.close(promise: nil) }
}

final class SessionChannelBridge: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    private let size: TerminalSize
    private let remoteCommand: String?
    private let onEvent: @Sendable (SSHSessionEvent) -> Void
    private let onClose: @Sendable (Bool) -> Void
    private var receivedExitStatus = false

    init(
        size: TerminalSize,
        remoteCommand: String? = nil,
        onEvent: @escaping @Sendable (SSHSessionEvent) -> Void,
        onClose: @escaping @Sendable (Bool) -> Void
    ) {
        self.size = size
        self.remoteCommand = remoteCommand
        self.onEvent = onEvent
        self.onClose = onClose
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        if let remoteCommand {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: remoteCommand, wantReply: true), promise: nil
            )
        } else {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = value.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        onEvent(value.type == .stdErr ? .stderr(Data(bytes)) : .stdout(Data(bytes)))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            receivedExitStatus = true
            onEvent(.exited(Int(exit.exitStatus)))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose(receivedExitStatus)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { onEvent(.status(error.localizedDescription)); context.close(promise: nil) }
}
