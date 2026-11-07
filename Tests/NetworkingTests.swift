import Testing
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Citadel
import SwiftData
@testable import SwiftPulse

struct NetworkingTests {
    @Test func socks5ServerNegotiatesAndConnects() throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        var captured: (String, Int)?
        let handler = SOCKS5ServerHandler { host, port in captured = (host, port); return loop.makeSucceededFuture(()) }
        try channel.pipeline.syncOperations.addHandler(handler)

        try channel.writeInbound(ByteBuffer(bytes: [0x05, 0x01, 0x00]))          // greeting: no-auth offered
        let choice: ByteBuffer? = try channel.readOutbound()
        #expect(choice.map { Array($0.readableBytesView) } == [0x05, 0x00])

        let request: [UInt8] = [0x05, 0x01, 0x00, 0x03, 11] + Array("example.com".utf8) + [0x01, 0xBB]
        try channel.writeInbound(ByteBuffer(bytes: request))                       // CONNECT example.com:443
        #expect(captured?.0 == "example.com")
        #expect(captured?.1 == 443)
        let reply: ByteBuffer? = try channel.readOutbound()
        #expect(reply.map { Array($0.readableBytesView.prefix(2)) } == [0x05, 0x00])
        #expect(throws: (any Error).self) { try channel.pipeline.syncOperations.handler(type: SOCKS5ServerHandler.self) } // handler removed itself
        _ = try channel.finish()
    }

    @Test func socks5RejectsUnsupportedCommand() throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        try channel.pipeline.syncOperations.addHandler(SOCKS5ServerHandler { _, _ in loop.makeSucceededFuture(()) })
        try channel.writeInbound(ByteBuffer(bytes: [0x05, 0x01, 0x00]))
        _ = try channel.readOutbound(as: ByteBuffer.self)
        try channel.writeInbound(ByteBuffer(bytes: [0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50]))  // BIND is not supported
        let reply: ByteBuffer? = try channel.readOutbound()
        #expect(reply?.getInteger(at: 1, as: UInt8.self) == 0x07)
        #expect(!channel.isActive)
    }

    @Test func glueBuffersDataUntilPartnerIsAttached() throws {
        let loop = EmbeddedEventLoop()
        let a = EmbeddedChannel(loop: loop), b = EmbeddedChannel(loop: loop)
        let (ha, hb) = GlueHandler.pair()
        var counted = 0
        ha.onBytes = { counted += $0 }
        try a.pipeline.syncOperations.addHandler(ha)
        try a.writeInbound(ByteBuffer(string: "early"))            // partner not attached yet → must not be lost
        #expect(try b.readOutbound(as: ByteBuffer.self) == nil)
        try b.pipeline.syncOperations.addHandler(hb)
        let flushed: ByteBuffer? = try b.readOutbound()
        #expect(flushed.map { String(buffer: $0) } == "early")
        try b.writeInbound(ByteBuffer(string: "reply"))
        let back: ByteBuffer? = try a.readOutbound()
        #expect(back.map { String(buffer: $0) } == "reply")
        #expect(counted == 5)
        _ = try a.finish()          // closing one side closes the partner as well
        #expect(!b.isActive)
    }

    @Test func proxyHandshakeHandlerReadsExactAndUntil() async throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        let handler = ProxyConnector.HandshakeHandler()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.writeInbound(ByteBuffer(bytes: [0x05, 0x00, 0xAA]))
        let first = try await handler.read(exactly: 2)
        #expect(first == [0x05, 0x00])
        try channel.writeInbound(ByteBuffer(string: "HTTP/1.1 200 Connection established\r\nProxy-Agent: x\r\n\r\nrest"))
        let leftover = try await handler.read(exactly: 1)
        #expect(leftover == [0xAA])
        let response = try await handler.readUntil(Array("\r\n\r\n".utf8))
        #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        _ = try channel.finish()
    }

    @Test func sshDataCodecUnwrapsChannelData() throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        try channel.pipeline.syncOperations.addHandler(SSHDataCodec())
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "abc"))))
        let inbound: ByteBuffer? = try channel.readInbound()
        #expect(inbound.map { String(buffer: $0) } == "abc")
        try channel.writeOutbound(ByteBuffer(string: "xyz"))
        let outbound: SSHChannelData? = try channel.readOutbound()
        if case .byteBuffer(let b)? = outbound?.data { #expect(String(buffer: b) == "xyz") } else { Issue.record("expected byteBuffer") }
        _ = try channel.finish()
    }
}

struct SFTPUploadPlanTests {
    @Test func aFolderBecomesItsDirectoriesThenItsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)/site")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("css/empty"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("12345".utf8).write(to: root.appendingPathComponent("css/app.css"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".env"))

        let plan = try SFTPSession.uploadPlan(from: root, to: "/var/www/site")
        #expect(plan.directories.first == "/var/www/site")
        #expect(Set(plan.directories) == ["/var/www/site", "/var/www/site/css", "/var/www/site/css/empty"])
        #expect(plan.directories.firstIndex(of: "/var/www/site/css")! < plan.directories.firstIndex(of: "/var/www/site/css/empty")!)
        #expect(Set(plan.files.map(\.remote)) == ["/var/www/site/index.html", "/var/www/site/css/app.css", "/var/www/site/.env"])
        #expect(plan.files.reduce(0) { $0 + $1.size } == 9)

        let single = try SFTPSession.uploadPlan(from: root.appendingPathComponent("index.html"), to: "/tmp/index.html")
        #expect(single.directories.isEmpty && single.files.map(\.remote) == ["/tmp/index.html"] && single.files[0].size == 3)
    }
}

struct TerminalReconnectTests {
    @Test func onlyDroppedShellsComeBack() {
        let dropped = NSError(domain: "NIO", code: 54) // connection reset
        #expect(TerminalSession.shouldReconnect(after: dropped, wasRunning: true, attempts: 0))
        #expect(TerminalSession.shouldReconnect(after: dropped, wasRunning: false, attempts: 2)) // a retry that failed too
        #expect(!TerminalSession.shouldReconnect(after: dropped, wasRunning: true, attempts: 3))  // gave up
        #expect(!TerminalSession.shouldReconnect(after: dropped, wasRunning: false, attempts: 0)) // never connected
        #expect(!TerminalSession.shouldReconnect(after: SSHClientError.allAuthenticationOptionsFailed, wasRunning: true, attempts: 0))
        #expect(!TerminalSession.shouldReconnect(after: SSHService.ConnectError.hostKeyRejected, wasRunning: true, attempts: 0))
        #expect(!TerminalSession.shouldReconnect(after: ConnectionSpec.SpecError.noCredentials, wasRunning: true, attempts: 1))
    }
}

struct LocalPaneTests {
    @Test func downloadsNeverReplaceAFile() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let taken: Set = ["/tmp/x/report.pdf", "/tmp/x/report 2.pdf", "/tmp/x/Makefile"]
        #expect(LocalFilePane.freeName(for: "report.pdf", in: folder, exists: taken.contains).lastPathComponent == "report 3.pdf")
        #expect(LocalFilePane.freeName(for: "Makefile", in: folder, exists: taken.contains).lastPathComponent == "Makefile 2")
        #expect(LocalFilePane.freeName(for: "new.txt", in: folder, exists: taken.contains).lastPathComponent == "new.txt")
    }
}

struct ConnectionOptionTests {
    @Test func proxyCommandsExpandLikeSSHConfig() {
        #expect(CommandConnector.expand("cloudflared access ssh --hostname %h", host: "db.example.com", port: 22, user: "u")
                == "cloudflared access ssh --hostname db.example.com")
        #expect(CommandConnector.expand("ssh -W %h:%p -l %r bastion 100%%", host: "10.0.0.2", port: 2198, user: "ops")
                == "ssh -W 10.0.0.2:2198 -l ops bastion 100%")
        #expect(CommandConnector.expand("nc %x %", host: "h", port: 1, user: "u") == "nc %x %")
    }

    @MainActor @Test func noAuthenticationNeedsOnlyAUser() throws {
        let context = ModelContext(AppSchema.container(inMemory: true))
        let fields = ConnectionSpec.Fields(host: "box.tailnet.ts.net", port: 22, authMethod: .noAuthentication, identity: nil, username: "root",
                                           sshKey: nil, proxy: nil, jumpHostIDs: [], proxyCommand: "  ")
        let spec = try ConnectionSpec.make(fields, in: context)
        #expect(spec.noAuthentication && spec.username == "root" && spec.password == nil && spec.privateKey == nil)
        #expect(spec.proxyCommand == nil) // blank means connect directly
    }
}

struct RemoteWalkTests {
    @Test func aRemoteFolderIsWalkedWithoutFollowingLinks() async throws {
        let tree: [String: [(name: String, type: UInt32, size: Int64)]] = [
            "/srv/site": [(".", 0o040000, 0), ("..", 0o040000, 0), ("index.html", 0o100000, 10), ("assets", 0o040000, 0),
                          ("current", 0o120000, 0), ("sock", 0o140000, 0)],
            "/srv/site/assets": [("app.js", 0o100000, 5), ("img", 0o040000, 0)],
            "/srv/site/assets/img": [],
        ]
        let walked = try await SFTPSession.walk("/srv/site") { tree[$0] ?? [] }
        #expect(walked.directories == ["assets", "assets/img"])
        #expect(walked.files.map(\.relative) == ["index.html", "assets/app.js"])
        #expect(walked.files.map(\.path) == ["/srv/site/index.html", "/srv/site/assets/app.js"])
        #expect(walked.files.reduce(0) { $0 + $1.size } == 15)
    }
}

struct ShellIntegrationTests {
    @Test func osc7ReportsBecomePaths() {
        #expect(TerminalSession.directory(fromOSC7: "file://web-1/var/www/html") == "/var/www/html")
        #expect(TerminalSession.directory(fromOSC7: "file://web-1/home/me/My%20Docs") == "/home/me/My Docs")
        #expect(TerminalSession.directory(fromOSC7: "file://web-1/home/me/My Docs") == "/home/me/My Docs")
        #expect(TerminalSession.directory(fromOSC7: "file:///srv") == "/srv")
        #expect(TerminalSession.directory(fromOSC7: "https://example.com/x") == nil)
    }

    @Test(arguments: ["/bin/bash", "/bin/zsh"])
    func theHookReportsTheFolderInBashAndZsh(shell: String) throws {
        #expect(!TerminalSession.shellIntegration.contains("\n"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-i", "-c", "cd /tmp; \(TerminalSession.shellIntegration) >/dev/null; _sp_cwd"]
        process.environment = ["TERM": "dumb", "HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(output.contains("\u{1b}]7;file://") && output.contains("/tmp\u{07}"), "\(shell): \(output.debugDescription)")
    }
}
