import Foundation
import SwiftData

@Model
final class Machine {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var authMethod: AuthMethod = AuthMethod.identity
    var identity: Identity?
    var username: String = ""
    var sshKey: SSHKey?
    var proxy: Proxy?
    /// A command the connection goes through instead of TCP, as in ssh_config (`%h` host, `%p` port, `%r` user).
    var proxyCommand: String = ""
    var useJumpHost: Bool = false
    var jumpHostIDs: [UUID] = []
    var connection: ConnectionKind = ConnectionKind.ssh
    var group: MachineGroup?
    var tags: [String] = []
    var showInDashboard: Bool = true
    /// Invisible to the MCP server: agents can't list, read or target it.
    var hiddenFromAgents: Bool = false
    var defaultSFTPPath: String = "/"
    var remark: String = ""
    var createdAt: Date = Date()

    init(name: String = "", host: String = "", port: Int = 22) {
        self.name = name
        self.host = host
        self.port = port
        self.remark = Machine.defaultRemark()
    }

    var displayName: String { name.isEmpty ? host : name }
    /// Keychain key for the machine's own password (Password or Key / Keyboard Interactive).
    var passwordKey: String { "machine.password.\(id.uuidString)" }

    static func defaultRemark(now: Date = .now) -> String {
        "Created on " + now.formatted(date: .abbreviated, time: .shortened)
    }
}

@Model
final class MachineGroup {
    var id: UUID = UUID()
    var name: String = ""
    var remark: String = ""
    var createdAt: Date = Date()
    @Relationship(deleteRule: .nullify, inverse: \Machine.group) var machines: [Machine]? = []

    init(name: String = "") {
        self.name = name
        self.remark = Machine.defaultRemark()
    }
}
