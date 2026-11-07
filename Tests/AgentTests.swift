import Testing
import Foundation
import SwiftData
@testable import SwiftPulse

/// Serialized: the tests point the shared secret store at their own temporary file.
@MainActor @Suite(.serialized)
struct AgentTests {
    static let secrets = ["S3cret-identity-pass", "S3cret-machine-pass", "S3cret-proxy-pass", "S3cret-passphrase",
                          "PRIVATEKEYBODYxyz123"]

    /// A store with a secret behind every kind of credential, and a server reading it.
    private func makeServer() throws -> (MCPServer, ModelContext) {
        let secretsFile = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tests-\(UUID().uuidString).json")
        KeychainService.overrideStoreURL = secretsFile
        let container = AppSchema.container(inMemory: true)
        let ctx = container.mainContext

        let key = SSHKey(name: "deploy", keyType: .ed25519, publicKey: "ssh-ed25519 AAAAPUBLIC deploy")
        key.hasPassphrase = true
        ctx.insert(key)
        KeychainService.set("-----BEGIN OPENSSH PRIVATE KEY-----\nPRIVATEKEYBODYxyz123\n-----END OPENSSH PRIVATE KEY-----", for: key.privateKeyKey)
        KeychainService.set("S3cret-passphrase", for: key.passphraseKey)

        let identity = Identity(name: "oci", username: "ubuntu")
        identity.hasPassword = true
        identity.sshKey = key
        ctx.insert(identity)
        KeychainService.set("S3cret-identity-pass", for: identity.passwordKey)

        let proxy = Proxy(name: "office", host: "10.0.0.9", port: 1080)
        proxy.auth = .usernamePassword
        proxy.username = "p"
        ctx.insert(proxy)
        KeychainService.set("S3cret-proxy-pass", for: proxy.passwordKey)

        let group = MachineGroup(name: "Production")
        ctx.insert(group)
        let web = Machine(name: "web-1", host: "10.0.0.1", port: 2222)
        web.identity = identity
        web.group = group
        web.tags = ["nginx"]
        web.proxy = proxy
        ctx.insert(web)
        let db = Machine(name: "db-1", host: "10.0.0.2")
        db.authMethod = .passwordOrKey
        db.username = "root"
        db.useJumpHost = true
        db.jumpHostIDs = [web.id]
        db.group = group
        ctx.insert(db)
        KeychainService.set("S3cret-machine-pass", for: db.passwordKey)

        let snippet = Snippet(name: "uptime")
        snippet.script = "uptime"
        ctx.insert(snippet)
        let rule = PortForwardingRule(name: "pg")
        rule.machineID = db.id
        rule.localPort = 15432
        rule.targetPort = 5432
        ctx.insert(rule)
        try ctx.save()
        return (MCPServer(container: container, dashboard: nil), ctx)
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: JSONValue = [:]) async -> String {
        let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments]]
        return await server.handle(request.encodedString(), session: MCPSession()) ?? ""
    }

    /// The text a tool call returned, unescaped.
    private func content(_ reply: String) throws -> String {
        try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))["result"]?["content"]?.array?.first?["text"]?.string ?? ""
    }

    private func reply(_ server: MCPServer, _ message: JSONValue) async throws -> JSONValue {
        let text = try #require(await server.handle(message.encodedString(), session: MCPSession()))
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func noReadToolOrResourceReturnsASecret() async throws {
        let (server, _) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        var replies: [String] = []
        for tool in ["list_hosts", "list_identities", "list_snippets", "list_port_forwards", "export_ssh_config", "get_metrics"] {
            replies.append(await call(server, tool))
        }
        replies.append(await call(server, "get_host", ["host": "db-1"]))
        replies.append(await call(server, "get_host", ["host": "web-1"]))
        replies.append(await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"swiftpulse://hosts"}}"#,
                                           session: MCPSession()) ?? "")
        replies.append(await server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, session: MCPSession()) ?? "")

        for (reply, secret) in replies.flatMap({ reply in Self.secrets.map { (reply, $0) } }) {
            #expect(!reply.contains(secret), "a reply leaks \(secret): \(reply.prefix(300))")
        }
        // The details agents need do come through.
        let hosts = replies[0]
        #expect(hosts.contains("web-1") && hosts.contains("10.0.0.1") && hosts.contains("ubuntu"))
        #expect(hosts.contains("key+password"))
        #expect(replies[1].contains("ssh-ed25519 AAAAPUBLIC deploy"))
        #expect(replies[4].contains("ProxyJump web-1"))
    }

    @Test func initializeNegotiatesTheProtocolVersion() async throws {
        let (server, _) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        let known = try await reply(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                             "params": ["protocolVersion": "2025-03-26", "clientInfo": ["name": "claude-code"]]])
        #expect(known["result"]?["protocolVersion"]?.string == "2025-03-26")
        let unknown = try await reply(server, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        #expect(unknown["result"]?["protocolVersion"]?.string == MCPServer.protocolVersions[0])
        #expect(unknown["result"]?["serverInfo"]?["name"]?.string == "swiftpulse")
    }

    @Test func jsonRPCErrorsAndNotifications() async throws {
        let (server, _) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        let missing = try await reply(server, ["jsonrpc": "2.0", "id": 7, "method": "nope"])
        #expect(missing["error"]?["code"]?.int == -32601)
        #expect(missing["id"]?.int == 7)
        let garbage = try JSONDecoder().decode(JSONValue.self, from: Data((await server.handle("{not json", session: MCPSession()) ?? "").utf8))
        #expect(garbage["error"]?["code"]?.int == -32700)
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, session: MCPSession()) == nil)

        let tools = try await reply(server, ["jsonrpc": "2.0", "id": 8, "method": "tools/list"])
        let list = try #require(tools["result"]?["tools"]?.array)
        #expect(list.count == AgentTools.definitions.count)
        for tool in list {
            #expect(tool["name"]?.string?.isEmpty == false)
            #expect(tool["description"]?.string?.isEmpty == false)
            #expect(tool["inputSchema"]?["type"]?.string == "object")
        }
    }

    @Test func promptsAreListedAndFilledIn() async throws {
        let (server, _) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        let list = try await reply(server, ["jsonrpc": "2.0", "id": 1, "method": "prompts/list"])
        #expect(list["result"]?["prompts"]?.array?.compactMap { $0["name"]?.string } == ["fleet_health", "fleet_update"])
        let health = try await reply(server, ["jsonrpc": "2.0", "id": 2, "method": "prompts/get",
                                              "params": ["name": "fleet_health", "arguments": ["group": "Production"]]])
        let text = health["result"]?["messages"]?.array?.first?["content"]?["text"]?.string ?? ""
        #expect(text.contains("group \"Production\"") && text.contains("Don't run anything"))
        let unknown = try await reply(server, ["jsonrpc": "2.0", "id": 3, "method": "prompts/get", "params": ["name": "nope"]])
        #expect(unknown["error"]?["code"]?.int == -32602)
    }

    @Test func targetsResolveAndDeduplicate() async throws {
        let (server, ctx) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        #expect(try server.targets(["targets": ["hosts": ["web-1", "10.0.0.1"]]]).map(\.name) == ["web-1"])
        #expect(Set(try server.targets(["targets": ["group": "production"]]).map(\.name)) == ["web-1", "db-1"])
        #expect(try server.targets(["targets": ["tag": "NGINX"]]).map(\.name) == ["web-1"])
        #expect(try server.targets(["targets": ["all": true, "hosts": ["db-1"]]]).count == 2)
        #expect(throws: AgentToolError.self) { try server.targets(["targets": [:]]) }
        #expect(throws: AgentToolError.self) { try server.targets(["targets": ["hosts": ["nope"]]]) }

        ctx.insert(Machine(name: "web-1", host: "10.0.0.3"))
        try ctx.save()
        #expect(throws: AgentToolError.self) { try server.machine(named: "web-1") } // ambiguous: use the id
    }

    @Test func aDeclinedRunNeverConnects() async throws {
        let (server, _) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        var asked: AgentRequest?
        server.approve = { request, _ in asked = request; return false }
        let text = await call(server, "run_command", ["targets": ["group": "Production"], "command": "reboot", "sudo": true, "task": "Patch"])
        #expect(text.contains("\"isError\":true"))
        #expect(text.contains("Declined by the user"))
        #expect(asked?.title == "Run on 2 machines with sudo")
        #expect(asked?.detail == "reboot")
        #expect(asked?.task == "Patch")
        #expect(Set(asked?.hosts ?? []) == ["web-1", "db-1"])
    }

    @Test func declinedRunsAreRecordedAndStepsOfATaskFoldTogether() async throws {
        let (server, ctx) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        server.approve = { _, _ in false }
        _ = await call(server, "run_command", ["targets": ["hosts": ["web-1"]], "command": "reboot", "task": "Patch"])
        var entries = try ctx.fetch(FetchDescriptor<AgentActivity>())
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == "declined")
        #expect(entries.first?.summary == "Patch")

        server.approve = { _, _ in true }
        _ = await call(server, "add_snippet", ["name": "a", "script": "true", "task": "patch"])
        _ = await call(server, "add_snippet", ["name": "b", "script": "true", "task": "Patch"])
        entries = try ctx.fetch(FetchDescriptor<AgentActivity>())
        #expect(entries.count == 1)
        #expect(entries.first?.steps.map(\.summary) == ["Run on 1 machine", "Add snippet a", "Add snippet b"])
        #expect(entries.first?.outcome == "ok")

        // Reads ask nothing and record nothing.
        _ = await call(server, "list_hosts")
        #expect(try ctx.fetchCount(FetchDescriptor<AgentActivity>()) == 1)
    }

    @Test func secretsAnAgentSetsAreWriteOnly() async throws {
        let (server, ctx) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        var asked: [AgentRequest] = []
        server.approve = { request, _ in asked.append(request); return true }

        let added = await call(server, "add_host", ["address": "10.0.0.7", "name": "cache-1", "username": "deploy",
                                                    "password": "N3w-machine-pass", "group": "Staging", "jump_hosts": ["web-1"]])
        #expect(!added.contains("N3w-machine-pass"))
        #expect(try content(added).contains("\"auth\" : \"password\""))
        let machine = try #require(try ctx.fetch(FetchDescriptor<Machine>()).first { $0.name == "cache-1" })
        #expect(KeychainService.get(machine.passwordKey) == "N3w-machine-pass")
        #expect(machine.group?.name == "Staging" && machine.useJumpHost)
        #expect(asked.last.map { !$0.detail.contains("N3w-machine-pass") && $0.detail.contains("password: set") } == true)

        let identity = await call(server, "add_identity", ["name": "agent-key", "username": "deploy", "generate": true])
        #expect(identity.contains("ssh-ed25519 "))
        #expect(!identity.contains("PRIVATE KEY"))
        let key = try #require(try ctx.fetch(FetchDescriptor<SSHKey>()).first { $0.name == "agent-key" })
        #expect(KeychainService.get(key.privateKeyKey)?.contains("BEGIN OPENSSH PRIVATE KEY") == true)

        // And nothing reads them back.
        for tool in ["list_hosts", "list_identities", "export_ssh_config"] {
            let reply = await call(server, tool)
            #expect(!reply.contains("N3w-machine-pass") && !reply.contains("PRIVATE KEY"))
        }

        _ = await call(server, "remove_host", ["host": "cache-1"])
        #expect(try ctx.fetch(FetchDescriptor<Machine>()).allSatisfy { $0.name != "cache-1" })
        #expect(KeychainService.get(machine.passwordKey) == nil)
    }

    @Test func agentsCanAddTailscaleAndProxyCommandMachines() async throws {
        let (server, ctx) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        server.approve = { _, _ in true }
        let added = try content(await call(server, "add_host", ["address": "box.tail1234.ts.net", "name": "box", "auth": "none",
                                                                 "username": "ops", "proxy_command": "cloudflared access ssh --hostname %h"]))
        #expect(added.contains("\"auth\" : \"none\"") && added.contains("cloudflared access ssh"))
        let box = try #require(try ctx.fetch(FetchDescriptor<Machine>()).first { $0.name == "box" })
        #expect(box.authMethod == .noAuthentication && box.username == "ops" && box.proxyCommand.hasPrefix("cloudflared"))
        #expect(try content(await call(server, "export_ssh_config", ["hosts": ["box"]])).contains("ProxyCommand cloudflared access ssh --hostname %h"))
    }

    @Test func grantsStayWithTheirConnection() {
        let first = MCPSession(), second = MCPSession()
        let now = Date()
        #expect(!AgentApproval.isGranted("claude-code", session: first, now: now))
        #expect(AgentApproval.apply(.session, client: "claude-code", session: first, now: now))
        #expect(AgentApproval.isGranted("claude-code", session: first, now: now))
        #expect(!AgentApproval.isGranted("claude-code", session: second, now: now)) // same name, other connection

        #expect(AgentApproval.apply(.hour, client: "codex", session: second, now: now))
        #expect(AgentApproval.isGranted("codex", session: second, now: now.addingTimeInterval(3500)))
        #expect(!AgentApproval.isGranted("codex", session: second, now: now.addingTimeInterval(3700)))

        #expect(AgentApproval.apply(.once, client: "x", session: MCPSession()))
        #expect(!AgentApproval.apply(.deny, client: "x", session: MCPSession()))
    }

    @Test func agentsReportAndReadActivity() async throws {
        let (server, _) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        _ = await call(server, "log_activity", ["hosts": ["db-1"], "summary": "Restarted postgres", "commands": ["systemctl restart postgresql"],
                                                "task": "Fix replication"])
        let db = await call(server, "get_activity", ["host": "db-1"])
        #expect(db.contains("Fix replication") && db.contains("systemctl restart postgresql"))
        let web = await call(server, "get_activity", ["host": "web-1"])
        #expect(!web.contains("Fix replication"))
    }

    @Test func readOnlyCommandsCantSmuggleAnythingIn() {
        let allowed = ["df", "systemctl status", "docker ps"]
        for ok in ["df", "df -h", "systemctl status nginx", "docker ps -a", "  df -h  "] {
            #expect(AgentApproval.isReadOnly(ok, allowed: allowed), "\(ok)")
        }
        for bad in ["dfx", "df -h; rm -rf /", "df && reboot", "df | sh", "df $(reboot)", "df `reboot`", "df > /etc/passwd",
                    "systemctl stop nginx", "systemctl statusx", "docker ps\nreboot", "df -h 'x'", "docker ps *", "", "rm -rf /"] {
            #expect(!AgentApproval.isReadOnly(bad, allowed: allowed), "\(bad)")
        }
        #expect(!AgentApproval.defaultReadOnlyCommands.contains("hostname"))
    }

    @Test func hiddenMachinesAreInvisibleToAgents() async throws {
        let (server, ctx) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        let web = try #require(try ctx.fetch(FetchDescriptor<Machine>()).first { $0.name == "web-1" })
        web.hiddenFromAgents = true
        try ctx.save()
        var asked = false
        server.approve = { _, _ in asked = true; return true }

        let hosts = try content(await call(server, "list_hosts"))
        #expect(!hosts.contains("10.0.0.1") && hosts.contains("db-1"))
        #expect(hosts.contains("(hidden)")) // db-1 goes through it, without naming it
        #expect(try content(await call(server, "get_host", ["host": "web-1"])).contains("No machine named"))
        #expect(throws: AgentToolError.self) { try server.targets(["targets": ["tag": "nginx"]]) }
        #expect(try server.targets(["targets": ["all": true]]).map(\.name) == ["db-1"])
        let config = try content(await call(server, "export_ssh_config"))
        #expect(!config.contains("web-1") && config.contains("hidden from agents"))
        _ = await call(server, "run_command", ["targets": ["hosts": ["web-1"]], "command": "id"])
        #expect(!asked) // never even reaches the user
    }

    @Test func runsThatOutlastTheWaitBecomeJobs() async throws {
        let (server, ctx) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        // No credentials: fails before any network, so the test never leaves the Mac.
        let bare = Machine(name: "bare", host: "10.9.9.9")
        bare.authMethod = .passwordOrKey
        ctx.insert(bare)
        try ctx.save()
        server.approve = { _, _ in true }

        let started = try content(await call(server, "run_command", ["targets": ["hosts": ["bare"]], "command": "uptime",
                                                                      "wait": 0, "task": "Check"]))
        let job = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(started.utf8))["job"]?.string)
        #expect(started.contains("\"status\" : \"running\""))
        #expect(try ctx.fetchCount(FetchDescriptor<AgentActivity>()) == 0) // recorded when the job ends, not now

        for _ in 0..<50 where !(try content(await call(server, "get_job", ["job": .string(job)])).contains("\"done\"")) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let done = try content(await call(server, "get_job", ["job": .string(job)]))
        #expect(done.contains("\"status\" : \"done\"") && done.contains("Enter a password or select an SSH key"))
        let entry = try #require(try ctx.fetch(FetchDescriptor<AgentActivity>()).first)
        #expect(entry.outcome == "failed on 1" && entry.task == "Check")

        // Stopping a finished job changes nothing; an unknown one is an error.
        #expect(try content(await call(server, "cancel_job", ["job": .string(job)])).contains("\"done\""))
        #expect(try content(await call(server, "get_job", ["job": "nope"])).contains("No job nope"))
    }

    @Test func clientsThatAskGetProgress() async throws {
        let (server, ctx) = try makeServer()
        defer { KeychainService.overrideStoreURL = nil }
        for name in ["bare-1", "bare-2"] {
            let machine = Machine(name: name, host: "10.9.9.9")
            machine.authMethod = .passwordOrKey
            machine.tags = ["bare"]
            ctx.insert(machine)
        }
        try ctx.save()
        server.approve = { _, _ in true }
        let session = MCPSession()
        var sent: [JSONValue] = []
        session.send = { sent.append((try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))) ?? .null) }

        let request: JSONValue = ["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                  "params": ["name": "run_command", "arguments": ["targets": ["tag": "bare"], "command": "true"],
                                             "_meta": ["progressToken": "t1"]]]
        _ = await server.handle(request.encodedString(), session: session)
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0["method"]?.string == "notifications/progress" && $0["params"]?["progressToken"]?.string == "t1" })
        #expect(sent.last?["params"]?["progress"]?.int == 2 && sent.last?["params"]?["total"]?.int == 2)
    }

    @Test func commandsAreQuotedAndExitCodesParsed() {
        #expect(AgentRunner.wrap("echo 'hi'", sudo: false) == #"sh -c 'echo '\''hi'\''' 2>&1; printf '\n__SWIFTPULSE_EXIT__%d\n' $?"#)
        #expect(AgentRunner.wrap("id", sudo: true).hasPrefix("sudo -n sh -c 'id'"))

        let parsed = AgentRunner.parse("line 1\r\nline 2\n\n__SWIFTPULSE_EXIT__3\n")
        #expect(parsed.output == "line 1\nline 2\n") // only the newline the wrapper adds is dropped
        #expect(parsed.exitCode == 3)
        // The command printing the marker itself doesn't fool it: the last one wins.
        #expect(AgentRunner.parse("__SWIFTPULSE_EXIT__9\n\n__SWIFTPULSE_EXIT__0\n").exitCode == 0)
        #expect(AgentRunner.parse("cut off").exitCode == nil)

        let (short, cutShort) = AgentRunner.tail(Data("abc".utf8), cap: 10)
        #expect(short == "abc" && !cutShort)
        let (long, cutLong) = AgentRunner.tail(Data("0123456789abc".utf8), cap: 4)
        #expect(long == "9abc" && cutLong)
    }
}
