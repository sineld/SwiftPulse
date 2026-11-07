import Foundation
import NIOCore

struct ProxySpec: Sendable {
    var host: String, port: Int, kind: ProxyKind, username: String?, password: String?
}

/// Opens a TCP tunnel to `target` through a SOCKS5 or HTTP CONNECT proxy; returns the raw channel ready for SSH.
enum ProxyConnector {
    enum ProxyError: LocalizedError {
        case rejected(String)
        var errorDescription: String? { if case .rejected(let s) = self { "Proxy refused the connection: \(s)" } else { nil } }
    }

    static func connect(through proxy: ProxySpec, to target: (host: String, port: Int), timeout: TimeInterval) async throws -> Channel {
        let channel = try await TCP.connect(host: proxy.host, port: proxy.port, timeout: timeout)
        let handshake = HandshakeHandler()
        try await channel.pipeline.addHandler(handshake).get()
        do {
            switch proxy.kind {
            case .socks5: try await socks5(channel, handshake, proxy, target)
            case .httpConnect: try await httpConnect(channel, handshake, proxy, target)
            }
        } catch { try? await channel.close(); throw error }
        try await channel.pipeline.removeHandler(handshake).get()
        return channel
    }

    private static func socks5(_ ch: Channel, _ h: HandshakeHandler, _ p: ProxySpec, _ t: (host: String, port: Int)) async throws {
        let useAuth = p.username?.isEmpty == false
        try await ch.writeAndFlush(ByteBuffer(bytes: [0x05, useAuth ? 2 : 1] + (useAuth ? [0x00, 0x02] : [0x00])))
        let choice = try await h.read(exactly: 2)
        guard choice[0] == 0x05 else { throw ProxyError.rejected("not a SOCKS5 server") }
        if choice[1] == 0x02 {
            let u = Array((p.username ?? "").utf8), pw = Array((p.password ?? "").utf8)
            try await ch.writeAndFlush(ByteBuffer(bytes: [0x01, UInt8(u.count)] + u + [UInt8(pw.count)] + pw))
            let r = try await h.read(exactly: 2)
            guard r[1] == 0x00 else { throw ProxyError.rejected("authentication failed") }
        } else if choice[1] != 0x00 { throw ProxyError.rejected("no acceptable authentication method") }
        let hostBytes = Array(t.host.utf8)
        try await ch.writeAndFlush(ByteBuffer(bytes: [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)] + hostBytes + [UInt8(t.port >> 8), UInt8(t.port & 0xff)]))
        let head = try await h.read(exactly: 4)
        guard head[1] == 0x00 else { throw ProxyError.rejected("SOCKS5 reply code \(head[1])") }
        switch head[3] {
        case 0x01: _ = try await h.read(exactly: 4 + 2)
        case 0x04: _ = try await h.read(exactly: 16 + 2)
        case 0x03: let n = try await h.read(exactly: 1); _ = try await h.read(exactly: Int(n[0]) + 2)
        default: throw ProxyError.rejected("bad address type")
        }
    }

    private static func httpConnect(_ ch: Channel, _ h: HandshakeHandler, _ p: ProxySpec, _ t: (host: String, port: Int)) async throws {
        var request = "CONNECT \(t.host):\(t.port) HTTP/1.1\r\nHost: \(t.host):\(t.port)\r\n"
        if let u = p.username, !u.isEmpty {
            request += "Proxy-Authorization: Basic \(Data("\(u):\(p.password ?? "")".utf8).base64EncodedString())\r\n"
        }
        request += "\r\n"
        try await ch.writeAndFlush(ByteBuffer(string: request))
        let response = try await h.readUntil(Array("\r\n\r\n".utf8))
        let status = String(decoding: response.prefix { $0 != 0x0d }, as: UTF8.self)
        guard status.split(separator: " ").dropFirst().first == "200" else { throw ProxyError.rejected(status) }
    }

    /// Buffers inbound bytes during the handshake and hands them out on demand.
    final class HandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private var buffer: [UInt8] = []
        private var waiter: (need: (inout [UInt8]) -> [UInt8]?, promise: CheckedContinuation<[UInt8], Error>)?
        private let lock = NSLock()

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let bytes = Array(unwrapInboundIn(data).readableBytesView)
            lock.lock(); buffer += bytes; let w = waiter
            if let w, let out = w.need(&buffer) { waiter = nil; lock.unlock(); w.promise.resume(returning: out) } else { lock.unlock() }
        }
        func channelInactive(context: ChannelHandlerContext) {
            lock.lock(); let w = waiter; waiter = nil; lock.unlock()
            w?.promise.resume(throwing: ProxyError.rejected("connection closed during handshake"))
        }

        func read(exactly n: Int) async throws -> [UInt8] {
            try await wait { buf in buf.count >= n ? Array(buf.prefix(n)).also { buf.removeFirst(n) } : nil }
        }
        func readUntil(_ marker: [UInt8]) async throws -> [UInt8] {
            try await wait { buf in
                guard let range = buf.firstRange(of: marker) else { return nil }
                let out = Array(buf[..<range.upperBound]); buf.removeFirst(range.upperBound); return out
            }
        }
        private func wait(_ need: @escaping (inout [UInt8]) -> [UInt8]?) async throws -> [UInt8] {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let out = need(&buffer) { lock.unlock(); cont.resume(returning: out) } else { waiter = (need, cont); lock.unlock() }
            }
        }
    }
}

private extension Array {
    func also(_ f: () -> Void) -> Array { f(); return self }
}
