import Darwin
import Foundation

/// The MCP server's endpoint: a Unix domain socket at `AppPaths.agentSocket`, readable and writable by its owner
/// only, and refusing peers that run as another user. There is no TCP port. `swiftpulse-mcp` bridges an agent's
/// stdio to it. Each message is one line of JSON-RPC.
final class AgentSocket: @unchecked Sendable {
    static let shared = AgentSocket()

    /// Set once at launch; without it requests get no reply.
    @MainActor var server: MCPServer?

    private let state = NSLock()
    private var listenerFD: Int32?
    private var connections: [ObjectIdentifier: Connection] = [:]

    var isRunning: Bool { state.withLock { listenerFD != nil } }

    /// Starts or stops the socket to match the "MCP Server" setting.
    func apply(enabled: Bool) {
        debugLog("[mcp] server \(enabled ? "on" : "off")")
        if enabled { start() } else { stop() }
    }

    func start() {
        state.withLock {
            guard listenerFD == nil else { return }
            let path = AppPaths.agentSocket.path
            do {
                let fd = try Self.openListener(at: path)
                listenerFD = fd
                debugLog("[mcp] listening on \(path)")
                Thread.detachNewThread { [weak self] in self?.acceptConnections(on: fd) }
            } catch {
                debugLog("[mcp] \(error)")
            }
        }
    }

    func stop() {
        let (fd, open): (Int32?, [Connection]) = state.withLock {
            let current = (listenerFD, Array(connections.values))
            listenerFD = nil
            connections = [:]
            return current
        }
        if let fd {
            close(fd) // ends acceptConnections
            unlink(AppPaths.agentSocket.path)
        }
        open.forEach { $0.hangUp() }
    }

    struct SocketError: Error, CustomStringConvertible {
        let description: String
        static func last(_ what: String) -> SocketError { SocketError(description: "\(what): \(String(cString: strerror(errno)))") }
    }

    /// A listening socket at `path` with mode 0600. The umask keeps the file private from the moment it exists,
    /// before chmod runs. A stale socket left by a previous run is replaced.
    static func openListener(at path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw SocketError(description: "socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (offset, byte) in path.utf8.enumerated() { raw[offset] = byte } // the rest stays zero
        }

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.last("socket()") }
        let savedMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(savedMask)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let error = SocketError.last("could not listen on \(path)")
            close(fd)
            throw error
        }
        return fd
    }

    /// True when the process on the other end runs as this user. Root and other users are refused.
    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    private func acceptConnections(on listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return // the listener was closed
            }
            guard Self.peerIsCurrentUser(fd) else {
                close(fd)
                continue
            }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let connection = Connection(fd: fd)
            state.withLock { connections[ObjectIdentifier(connection)] = connection }
            Thread.detachNewThread { [weak self] in self?.serve(connection) }
        }
    }

    private func serve(_ connection: Connection) {
        let session = MCPSession()
        session.send = { connection.send($0) }
        defer {
            state.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
            connection.close()
            Task { @MainActor [weak self] in self?.server?.disconnected(session) }
        }
        connection.readLines { line in
            // Requests run independently, so one waiting for the user's approval doesn't block a ping or a list.
            Task { @MainActor [weak self] in
                guard let server = self?.server, let reply = await server.handle(line, session: session) else { return }
                connection.send(reply)
            }
        }
    }

    /// One connected client. Lines are read on the client's own thread; replies can come from any task, so sending
    /// is serialized and every reply goes out whole.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var closed = false
        /// A client that never finishes a line is dropped instead of growing the buffer without bound.
        private static let maxPendingBytes = 16 << 20

        init(fd: Int32) { self.fd = fd }

        /// Calls `body` with every non-blank line until the client hangs up.
        func readLines(_ body: (String) -> Void) {
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return }
                pending.append(contentsOf: chunk[0 ..< count])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self)
                    pending = pending.subdata(in: (newline + 1) ..< pending.endIndex)
                    if !line.allSatisfy(\.isWhitespace) { body(line) }
                }
                if pending.count > Self.maxPendingBytes { return }
            }
        }

        /// Sends `message` and a newline, all of it, unless the connection is closed.
        func send(_ message: String) {
            let bytes = Array((message + "\n").utf8)
            lock.withLock {
                guard !closed else { return }
                var sent = 0
                while sent < bytes.count {
                    let count = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return }
                    sent += count
                }
            }
        }

        /// Wakes the reading thread, which then closes the descriptor.
        func hangUp() {
            lock.withLock {
                if !closed { shutdown(fd, SHUT_RDWR) }
            }
        }

        func close() {
            lock.withLock {
                guard !closed else { return }
                closed = true
                Darwin.close(fd)
            }
        }
    }
}
