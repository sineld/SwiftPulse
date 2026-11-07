import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Translates SSH child-channel frames to plain ByteBuffers (Citadel's equivalent is internal).
final class SSHDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = frame.data, frame.type == .channel else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

/// Pipes bytes between two channels; closing one closes the other. Install one instance per side via `GlueHandler.pair()`.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pending: [ByteBuffer] = []   // data that arrived before this side was attached
    var onBytes: ((Int) -> Void)?

    static func pair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b; b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        let queued = pending; pending.removeAll()
        for buffer in queued { context.write(wrapOutboundOut(buffer), promise: nil) }
        if !queued.isEmpty { context.flush() }
    }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; partner = nil }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        onBytes?(buffer.readableBytes)
        partner?.forward(buffer)
    }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.onLoop { $0.flush() } }
    func channelInactive(context: ChannelHandlerContext) { partner?.onLoop { $0.close(promise: nil) }; partner = nil }

    /// Runs `body` with this side's context on its own event loop (the two glued channels may live on different loops).
    private func onLoop(_ body: @escaping (ChannelHandlerContext) -> Void) {
        guard let context else { return }
        if context.eventLoop.inEventLoop { body(context) } else { context.eventLoop.execute { body(context) } }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    private func forward(_ buffer: ByteBuffer) {
        guard context != nil else { pending.append(buffer); return }
        onLoop { $0.write(self.wrapOutboundOut(buffer), promise: nil) }
    }
}

enum TCP {
    /// Plain TCP connection with no handlers installed.
    static func connect(host: String, port: Int, timeout: TimeInterval = 15) async throws -> Channel {
        try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(Int64(timeout)))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connect(host: host, port: port).get()
    }
}
