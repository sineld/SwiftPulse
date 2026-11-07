import Foundation
import SwiftData

// What an agent may know about the store. Each type is built from a model and has no field that could hold a
// secret (no password, private key or passphrase), so everything the MCP server returns is one of these.

/// A machine as an agent sees it.
struct AgentHost: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var address: String
    var port: Int
    var username: String
    var group: String?
    var tags: [String]
    var comment: String
    /// "key", "password", "key+password", or "missing" when SwiftPulse has nothing to sign in with.
    var auth: String
    /// The shared identity's name, nil when the machine keeps its own credentials.
    var identity: String?
    var keyType: String?
    /// Names of the jump hosts the connection goes through, in order.
    var jumpHosts: [String]
    var proxy: String?
    var proxyCommand: String?
    /// Whether the dashboard monitors it, which is where live metrics come from.
    var monitored: Bool

    @MainActor
    init(_ machine: Machine, in context: ModelContext) {
        id = machine.id.uuidString
        name = machine.displayName
        address = machine.host
        port = machine.port
        group = machine.group?.name
        tags = machine.tags
        comment = machine.remark
        monitored = machine.showInDashboard
        proxy = machine.proxy?.name
        proxyCommand = machine.proxyCommand.nilIfEmpty

        var hasKey = false, hasPassword = false
        switch machine.authMethod {
        case .identity:
            username = machine.identity?.username ?? ""
            identity = machine.identity?.name
            keyType = machine.identity?.sshKey?.keyType.rawValue
            hasKey = machine.identity?.sshKey != nil
            hasPassword = machine.identity?.hasPassword ?? false
        case .passwordOrKey, .keyboardInteractive, .noAuthentication:
            username = machine.username
            identity = nil
            keyType = machine.authMethod == .passwordOrKey ? machine.sshKey?.keyType.rawValue : nil
            hasKey = machine.authMethod == .passwordOrKey && machine.sshKey != nil
            hasPassword = KeychainService.get(machine.passwordKey)?.isEmpty == false
        }
        auth = switch (hasKey, hasPassword) {
        case (true, true): "key+password"
        case (true, false): "key"
        case (false, true): "password"
        case (false, false): "missing"
        }
        if machine.authMethod == .noAuthentication { auth = "none" }

        let hops = machine.useJumpHost ? machine.jumpHostIDs : []
        let all = (try? context.fetch(FetchDescriptor<Machine>())) ?? []
        jumpHosts = hops.map { id in
            guard let hop = all.first(where: { $0.id == id }) else { return id.uuidString }
            return hop.hiddenFromAgents ? "(hidden)" : hop.displayName
        }
    }

    /// The alias `export_ssh_config` gives the machine: its name, lowercased, with only letters, digits, `-` and `.`.
    var alias: String {
        let cleaned = String(name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" })
        return cleaned.isEmpty ? address : cleaned
    }

    /// One `Host` block of an ssh_config, with no key or password in it.
    func sshConfigBlock(jumpAliases: [String]) -> String {
        var lines = ["Host \(alias)", "    HostName \(address)"]
        if port != 22 { lines.append("    Port \(port)") }
        if !username.isEmpty { lines.append("    User \(username)") }
        if !jumpAliases.isEmpty { lines.append("    ProxyJump \(jumpAliases.joined(separator: ","))") }
        if let proxyCommand { lines.append("    ProxyCommand \(proxyCommand)") }
        return lines.joined(separator: "\n")
    }
}

/// An identity as an agent sees it: its key's public half only.
struct AgentIdentity: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var username: String
    var hasPassword: Bool
    var keyName: String?
    var keyType: String?
    var publicKey: String?
    var usedBy: [String]

    init(_ identity: Identity, machines: [Machine]) {
        id = identity.id.uuidString
        name = identity.name
        username = identity.username
        hasPassword = identity.hasPassword
        keyName = identity.sshKey?.name
        keyType = identity.sshKey?.keyType.rawValue
        publicKey = identity.sshKey.flatMap { $0.publicKey.isEmpty ? nil : $0.publicKey }
        usedBy = machines.filter { $0.authMethod == .identity && $0.identity?.id == identity.id }.map(\.displayName)
    }
}

struct AgentSnippet: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var package: String?
    var script: String
    var comment: String

    init(_ snippet: Snippet) {
        id = snippet.id.uuidString
        name = snippet.name
        package = snippet.package?.name
        script = snippet.script
        comment = snippet.remark
    }
}

struct AgentForward: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// "local", "remote" or "dynamic" (a SOCKS5 proxy on this Mac).
    var mode: String
    var machine: String?
    var localHost: String
    var localPort: Int
    var targetHost: String?
    var targetPort: Int?
    var autoStart: Bool

    init(_ rule: PortForwardingRule, machines: [Machine]) {
        id = rule.id.uuidString
        name = rule.name
        mode = rule.mode.rawValue
        machine = rule.machineID.flatMap { id in machines.first { $0.id == id }?.displayName }
        localHost = rule.localHost
        localPort = rule.localPort
        targetHost = rule.mode == .dynamic ? nil : rule.targetHost
        targetPort = rule.mode == .dynamic ? nil : rule.targetPort
        autoStart = rule.autoStart
    }
}
