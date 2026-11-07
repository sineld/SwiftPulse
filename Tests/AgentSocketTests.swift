import Darwin
import Foundation
import Testing
@testable import SwiftPulse

struct AgentSocketTests {

    /// sun_path holds 104 bytes, so the test socket lives directly in /tmp rather than the long temporary directory.
    private func scratchSocketPath() -> String { "/tmp/sp-test-\(UUID().uuidString.prefix(8)).sock" }

    @Test func listenerIsPrivateAndAcceptsThisUser() throws {
        let path = scratchSocketPath()
        let listener = try AgentSocket.openListener(at: path)
        defer { close(listener); unlink(path) }

        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (offset, byte) in path.utf8.enumerated() { raw[offset] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connected == 0)

        let peer = accept(listener, nil, nil)
        defer { close(peer) }
        #expect(peer >= 0)
        #expect(AgentSocket.peerIsCurrentUser(peer))
    }

    @Test func staleSocketIsReplaced() throws {
        let path = scratchSocketPath()
        let first = try AgentSocket.openListener(at: path)
        close(first)                      // the file stays behind, as after a crash
        let second = try AgentSocket.openListener(at: path)
        close(second)
        unlink(path)
    }

    @Test func overlongPathIsRefused() {
        #expect(throws: AgentSocket.SocketError.self) {
            try AgentSocket.openListener(at: "/tmp/" + String(repeating: "x", count: 200))
        }
    }

    @Test func jsonRoundTripKeepsTypes() throws {
        let text = #"{"flag":true,"list":[1,2.5,"three",null],"nested":{"n":-7}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(value["flag"]?.bool == true)
        #expect(value["list"]?.array?.count == 4)
        #expect(value["list"]?.array?[0] == .number(1))
        #expect(value["list"]?.array?[3] == .null)
        #expect(value["nested"]?["n"]?.int == -7)
        #expect(value.encodedString() == text)   // sorted keys, whole numbers without a fraction
        #expect(JSONValue.string("42").int == 42)
        #expect(JSONValue.number(3).string == "3")
        #expect(JSONValue.number(2.5).string == "2.5")
        #expect(JSONValue.array(["a", 1]).strings == ["a", "1"])
        #expect(JSONValue.string("solo").strings == ["solo"])
    }
}
