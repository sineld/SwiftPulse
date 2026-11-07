import Foundation
import SwiftData
import Citadel
import NIOCore
import NIOPosix
import NIOSSH

/// A running port-forwarding tunnel (local, remote or dynamic/SOCKS5) over one SSH connection.
@Observable @MainActor
final class ForwardingSession: Identifiable {
    enum State: Equatable { case connecting, running, stopped(String?) }

    let id = UUID()
    let rule: PortForwardingRule
    let machine: Machine
    let record: SessionRecord
    private(set) var state: State = .connecting
    private(set) var connections = 0
    private(set) var bytes: Int64 = 0
    private(set) var boundPort: Int = 0

    private let container: ModelContainer
    private var client: SSHClient?
    private var listener: Channel?
    private var remoteTask: Task<Void, Never>?

    var stateText: String {
        switch state {
        case .connecting: "\(rule.mode.title) · Connecting"
        case .running: "\(rule.mode.title) · Running"
        case .stopped(let e): e.map { "\(rule.mode.title) · \($0)" } ?? "\(rule.mode.title) · Stopped"
        }
    }
    var routeText: String {
        switch rule.mode {
        case .local: "\(rule.localHost):\(boundPort) → \(rule.targetHost):\(rule.targetPort)"
        case .remote: "\(machine.host):\(boundPort) → \(rule.targetHost):\(rule.targetPort)"
        case .dynamic: "SOCKS5 \(rule.localHost):\(boundPort)"
        }
    }

    init(rule: PortForwardingRule, machine: Machine, record: SessionRecord, container: ModelContainer) {
        self.rule = rule; self.machine = machine; self.record = record; self.container = container
        Task { await start() }
    }

    func start() async {
        state = .connecting
        do {
            let spec = try ConnectionSpec.make(for: machine, in: ModelContext(container))
            let client = try await SSHService.connect(spec, container: container)
            self.client = client
            switch rule.mode {
            case .local: try await startLocal(client)
            case .dynamic: try await startDynamic(client)
            case .remote: startRemote(client)
            }
            state = .running
        } catch { state = .stopped(error.localizedDescription) }
    }

    func stop() {
        remoteTask?.cancel(); remoteTask = nil
        let l = listener, c = client; listener = nil; client = nil
        Task { try? await l?.close(); try? await c?.close() }
        state = .stopped(nil)
        record.lastActiveAt = .now
    }

    // MARK: local: listen locally, open direct-tcpip per accepted connection
    private func startLocal(_ client: SSHClient) async throws {
        let target = (rule.targetHost, rule.targetPort)
        listener = try await listen { [weak self] inbound in
            guard let self else { return inbound.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
            return self.tunnel(inbound, client: client, to: target)
        }
    }

    // MARK: dynamic: local SOCKS5 server, direct-tcpip to whatever the client asks for
    private func startDynamic(_ client: SSHClient) async throws {
        listener = try await listen { [weak self] inbound in
            guard let self else { return inbound.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
            return inbound.pipeline.addHandler(SOCKS5ServerHandler { host, port in
                self.tunnel(inbound, client: client, to: (host, port))
            })
        }
    }

    private func listen(_ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) async throws -> Channel {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer(initializer)
            .bind(host: rule.localHost, port: rule.localPort).get()
        boundPort = channel.localAddress?.port ?? rule.localPort
        return channel
    }

    /// Opens a direct-tcpip channel and glues it to `inbound` (the local socket). Runs on the event loop.
    private nonisolated func tunnel(_ inbound: Channel, client: SSHClient, to target: (String, Int)) -> EventLoopFuture<Void> {
        let promise = inbound.eventLoop.makePromise(of: Void.self)
        let (a, b) = GlueHandler.pair()
        a.onBytes = { [weak self] n in Task { @MainActor in self?.bytes += Int64(n) } }
        Task {
            do {
                let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                let ssh = try await client.createDirectTCPIPChannel(using: .init(targetHost: target.0, targetPort: target.1, originatorAddress: originator)) { channel in
                    channel.pipeline.addHandler(b)
                }
                try await inbound.pipeline.addHandler(a).get()
                _ = ssh
                await MainActor.run { self.connections += 1 }
                promise.succeed(())
            } catch {
                debugLog("[forward] tunnel failed: \(String(reflecting: error))")
                promise.fail(error)
                try? await inbound.close()
            }
        }
        return promise.futureResult
    }

    // MARK: remote: server listens, we connect each forwarded connection to the local target
    private func startRemote(_ client: SSHClient) {
        let target = (rule.targetHost, rule.targetPort)
        let host = rule.localHost.isEmpty || rule.localHost == "127.0.0.1" ? "localhost" : rule.localHost
        remoteTask = Task { [weak self] in
            do {
                try await client.withRemotePortForward(host: host, port: rule.localPort, onOpen: { info in
                    await MainActor.run { self?.boundPort = info.boundPort }
                }, handleChannel: { channel, _ in
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    Task {
                        do {
                            let (a, b) = GlueHandler.pair()
                            a.onBytes = { n in Task { @MainActor in self?.bytes += Int64(n) } }
                            let local = try await TCP.connect(host: target.0, port: target.1)
                            try await local.pipeline.addHandler(b).get()
                            try await channel.pipeline.addHandlers([SSHDataCodec(), a]).get()
                            await MainActor.run { self?.connections += 1 }
                            promise.succeed(())
                        } catch { promise.fail(error) }
                    }
                    return promise.futureResult
                })
            } catch {
                if !Task.isCancelled { await MainActor.run { self?.state = .stopped(error.localizedDescription) } }
            }
        }
    }
}

/// Minimal SOCKS5 server (no auth, CONNECT only). On CONNECT it asks `open` to attach the tunnel, then removes itself.
final class SOCKS5ServerHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private enum Stage { case greeting, request, done }
    private var stage = Stage.greeting
    private var buffer = ByteBuffer()
    private let open: (String, Int) -> EventLoopFuture<Void>
    init(open: @escaping (String, Int) -> EventLoopFuture<Void>) { self.open = open }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        switch stage {
        case .greeting:
            guard let n = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self), buffer.readableBytes >= 2 + Int(n) else { return }
            buffer.moveReaderIndex(forwardBy: 2 + Int(n))
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [0x05, 0x00])), promise: nil)
            stage = .request
            if buffer.readableBytes > 0 { channelRead(context: context, data: NIOAny(ByteBuffer())) }
        case .request:
            guard buffer.readableBytes >= 4, let cmd = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self),
                  let atyp = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self) else { return }
            var idx = buffer.readerIndex + 4
            let host: String
            switch atyp {
            case 0x01:
                guard let b = buffer.getBytes(at: idx, length: 4) else { return }; host = b.map(String.init).joined(separator: "."); idx += 4
            case 0x03:
                guard let len = buffer.getInteger(at: idx, as: UInt8.self), let b = buffer.getBytes(at: idx + 1, length: Int(len)) else { return }
                host = String(decoding: b, as: UTF8.self); idx += 1 + Int(len)
            case 0x04:
                guard let b = buffer.getBytes(at: idx, length: 16) else { return }
                host = stride(from: 0, to: 16, by: 2).map { String(format: "%02x%02x", b[$0], b[$0 + 1]) }.joined(separator: ":"); idx += 16
            default: reply(context, 0x08); return
            }
            guard let port = buffer.getInteger(at: idx, as: UInt16.self) else { return }
            buffer.moveReaderIndex(to: idx + 2)
            guard cmd == 0x01 else { reply(context, 0x07); return }
            stage = .done
            open(host, Int(port)).whenComplete { [self] result in
                switch result {
                case .success:
                    self.reply(context, 0x00)
                    context.pipeline.removeHandler(self, promise: nil)
                case .failure: self.reply(context, 0x05)
                }
            }
        case .done: break
        }
    }

    private func reply(_ context: ChannelHandlerContext, _ code: UInt8) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])), promise: nil)
        if code != 0 { context.close(promise: nil) }
    }
}
