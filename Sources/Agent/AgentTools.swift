import Foundation
import SwiftData

/// The MCP tools. Reads answer at once; anything that changes the store, starts a forward or runs a command
/// waits for the user's approval. No tool returns a password, a private key or a passphrase: machines come back
/// as `AgentHost`, identities as `AgentIdentity`. Secrets an agent sets go straight into the secret store.
@MainActor
enum AgentTools {
    // MARK: - Schema helpers

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    static let string: JSONValue = ["type": "string"]
    static let integer: JSONValue = ["type": "integer"]
    static let boolean: JSONValue = ["type": "boolean"]
    static let strings: JSONValue = ["type": "array", "items": ["type": "string"]]

    static func describe(_ type: JSONValue, _ text: String) -> JSONValue {
        guard case var .object(object) = type else { return type }
        object["description"] = .string(text)
        return .object(object)
    }

    static func tool(_ name: String, _ description: String, _ input: JSONValue, readOnly: Bool) -> JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": input,
         "annotations": ["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(name.hasPrefix("remove_") || name.hasPrefix("run_"))]]
    }

    static let task: JSONValue = describe(string, "Short name of the goal this step serves, e.g. \"Install nginx\". Use the same "
        + "task for every step toward one goal: they are kept as one entry in the machines' history, so the next agent sees what was done")

    /// Tools that change something take a task.
    static func withTask(_ definition: JSONValue) -> JSONValue {
        guard case var .object(tool) = definition, tool["annotations"]?["readOnlyHint"] == .bool(false),
              case var .object(input) = tool["inputSchema"] ?? .null, case var .object(properties) = input["properties"] ?? .null
        else { return definition }
        properties["task"] = task
        input["properties"] = .object(properties)
        tool["inputSchema"] = .object(input)
        return .object(tool)
    }

    static let targets: JSONValue = describe(schema([
        "hosts": describe(strings, "Machine ids, names or addresses"),
        "group": describe(string, "Every machine in this group"),
        "tag": describe(string, "Every machine with this tag"),
        "all": describe(boolean, "Every machine"),
    ]), "Which machines")

    static let hostFields: [String: JSONValue] = [
        "address": describe(string, "IP or hostname"),
        "port": describe(integer, "SSH port, 22 when left out"),
        "name": describe(string, "Label; the address when left out"),
        "username": describe(string, "User to sign in as with the machine's own password or key; root when left out"),
        "group": describe(string, "Group name; created when it doesn't exist"),
        "tags": strings,
        "comment": string,
        "identity": describe(string, "Id or name of an identity (user plus password and/or key) to sign in with"),
        "key": describe(string, "Id or name of an SSH key to sign in with, with username"),
        "password": describe(string, "Password to sign in with, kept with this machine. Write-only: never returned"),
        "jump_hosts": describe(strings, "Machines (ids or names) to connect through, in order"),
        "auth": describe(string, "\"none\": sign in with no password or key, for a server that trusts the connection itself (Tailscale SSH); give username"),
        "proxy_command": describe(string, "A command the connection goes through instead of TCP, as in ssh_config ProxyCommand: %h host, %p port, %r user, "
                                  + "e.g. \"cloudflared access ssh --hostname %h\". Empty connects directly"),
        "dashboard": describe(boolean, "Monitor it on the dashboard; true when left out"),
    ]

    // MARK: - Definitions

    static let definitions: [JSONValue] = toolList.map(withTask)

    static let toolList: [JSONValue] = [
        tool("list_hosts", "Machines SwiftPulse knows: address, port, user, group, tags, how they sign in, jump hosts. No secrets.",
             schema(["query": describe(string, "Matches name, address, group, tags and comment"), "group": string, "tag": string]), readOnly: true),
        tool("get_host", "One machine, with its live metrics when the dashboard monitors it.",
             schema(["host": describe(string, "Id, name or address")], required: ["host"]), readOnly: true),
        tool("get_metrics", "Live CPU, memory, swap, disks, load, network, disk I/O, temperature, top processes and OS of machines the dashboard monitors.",
             schema(["hosts": describe(strings, "Ids, names or addresses; every monitored machine when left out")]), readOnly: true),
        tool("export_ssh_config", "ssh_config Host blocks for machines (HostName, Port, User, ProxyJump; no keys), for agents that use their own ssh.",
             schema(["hosts": describe(strings, "Ids, names or addresses; every machine when left out")]), readOnly: true),
        tool("run_command", "Run a shell command on machines, signed in with SwiftPulse's saved credentials. The user approves first. "
             + "Returns each machine's exit code and output (stdout and stderr together, the last 1 MB).",
             schema(["targets": targets, "command": string,
                     "sudo": describe(boolean, "Run with sudo -n (fails rather than asking for a password)"),
                     "timeout": describe(integer, "Seconds per machine, 300 by default"),
                     "concurrency": describe(integer, "Machines at once, 8 by default, at most 32"),
                     "wait": describe(integer, "Seconds to wait for every machine before returning a job id to follow with get_job; "
                                      + "120 by default. The command keeps running either way.")],
                    required: ["targets", "command"]), readOnly: false),
        tool("run_snippet", "Run a saved snippet on machines, like run_command.",
             schema(["targets": targets, "snippet": describe(string, "Snippet id or name"), "sudo": boolean,
                     "timeout": integer, "concurrency": integer, "wait": integer], required: ["targets", "snippet"]), readOnly: false),
        tool("get_job", "A run that outlasted its wait: running or done, and the results of the machines that finished.",
             schema(["job": string], required: ["job"]), readOnly: true),
        tool("cancel_job", "Stop a running job; machines still running are disconnected (their command may be killed midway).",
             schema(["job": string], required: ["job"]), readOnly: false),
        tool("add_host", "Add a machine. It signs in with an identity, or with its own username plus password and/or SSH key.",
             schema(hostFields, required: ["address"]), readOnly: false),
        tool("update_host", "Change a machine; only the fields given change.",
             schema(hostFields.merging(["host": describe(string, "Id, name or address of the machine")]) { $1 }, required: ["host"]), readOnly: false),
        tool("remove_host", "Remove a machine from SwiftPulse; its open sessions are closed.", schema(["host": string], required: ["host"]), readOnly: false),
        tool("list_identities", "Identities and their SSH keys: name, user, key type, public key, the machines using them. Private keys and passwords are never returned.",
             schema([:]), readOnly: true),
        tool("add_identity", "Add an identity: a username with a password and/or an SSH key. generate: true makes a new Ed25519 key and returns "
             + "its public key, to put in authorized_keys. Or give private_key (write-only, never returned).",
             schema(["name": string, "username": string, "generate": boolean, "private_key": describe(string, "Write-only"),
                     "public_key": string, "passphrase": describe(string, "Write-only"), "password": describe(string, "Write-only")],
                    required: ["name", "username"]), readOnly: false),
        tool("remove_identity", "Remove an identity; machines using it lose their sign-in. Its SSH key stays.",
             schema(["identity": string], required: ["identity"]), readOnly: false),
        tool("list_snippets", "Saved snippets with their scripts.", schema(["query": string]), readOnly: true),
        tool("add_snippet", "Save a snippet.", schema(["name": string, "script": string, "package": describe(string, "Package name; created when it doesn't exist"),
                                                      "comment": string], required: ["name", "script"]), readOnly: false),
        tool("update_snippet", "Change a snippet; only the fields given change.",
             schema(["snippet": string, "name": string, "script": string, "package": string, "comment": string], required: ["snippet"]), readOnly: false),
        tool("remove_snippet", "Remove a snippet.", schema(["snippet": string], required: ["snippet"]), readOnly: false),
        tool("list_port_forwards", "Port forwarding rules (local, remote or dynamic SOCKS5), their ports and targets, and whether they run.", schema([:]), readOnly: true),
        tool("add_port_forward", "Add a port forward through a machine. local: a port on this Mac reaches target_host:target_port from the machine; "
             + "remote: a port on the machine reaches it from this Mac; dynamic: a SOCKS5 proxy on this Mac.",
             schema(["host": string, "mode": ["type": "string", "enum": ["local", "remote", "dynamic"]], "name": string,
                     "local_port": integer, "local_host": describe(string, "127.0.0.1 when left out"),
                     "target_host": describe(string, "127.0.0.1 when left out"), "target_port": integer,
                     "auto_start": boolean, "start": describe(boolean, "Start it now")],
                    required: ["host", "mode", "local_port"]), readOnly: false),
        tool("start_port_forward", "Start a port forward.", schema(["forward": describe(string, "Port forward id or name")], required: ["forward"]), readOnly: false),
        tool("stop_port_forward", "Stop a port forward.", schema(["forward": string], required: ["forward"]), readOnly: false),
        tool("remove_port_forward", "Remove a port forward, stopping it first.", schema(["forward": string], required: ["forward"]), readOnly: false),
        tool("list_containers", "Docker containers on a machine: name, image, state, status, ports, compose project and live CPU/memory.",
             schema(["host": string], required: ["host"]), readOnly: true),
        tool("container_logs", "The last lines of a container's logs, with timestamps.",
             schema(["host": string, "container": describe(string, "Container name or id"), "lines": describe(integer, "200 by default, at most 2000")],
                    required: ["host", "container"]), readOnly: true),
        tool("get_activity", "What agents did on machines, newest first: runs and changes through SwiftPulse (approved, declined or failed), "
             + "and what agents reported with log_activity. Read it before working on a machine.",
             schema(["host": describe(string, "Id, name or address; every machine when left out"), "limit": describe(integer, "50 by default")]), readOnly: true),
        tool("log_activity", "Record what you did on machines by other means than SwiftPulse (your own ssh, scp, a deploy), so the user and later agents see it. Never include secrets.",
             schema(["hosts": describe(strings, "Machine ids, names or addresses"), "summary": describe(string, "One line: what you did"),
                     "details": describe(string, "What changed and why"), "commands": describe(strings, "The commands you ran")],
                    required: ["hosts", "summary"]), readOnly: false),
    ]

    // MARK: - Calls

    static func call(_ name: String, arguments a: JSONValue, server: MCPServer, call: AgentCall) async throws -> JSONValue {
        let context = server.context
        switch name {
        case "list_hosts":
            return .from(server.hosts(matching: a))

        case "get_host":
            let machine = try server.machine(named: a["host"]?.string ?? "")
            guard case var .object(host) = JSONValue.from(AgentHost(machine, in: context)) else { return .null }
            host["metrics"] = metrics(for: machine, dashboard: server.dashboard)
            return .object(host)

        case "get_metrics":
            let references = a["hosts"]?.strings ?? []
            let list = references.isEmpty ? server.machines.filter(\.showInDashboard) : try references.map(server.machine(named:))
            return .array(list.map { machine in
                ["host": .string(machine.displayName), "id": .string(machine.id.uuidString),
                 "metrics": metrics(for: machine, dashboard: server.dashboard)]
            })

        case "export_ssh_config":
            let references = a["hosts"]?.strings ?? []
            let list = references.isEmpty ? server.machines : try references.map(server.machine(named:))
            let hosts = server.machines.map { AgentHost($0, in: context) }
            let blocks = list.map { machine -> String in
                let hops = machine.useJumpHost ? machine.jumpHostIDs : []
                let aliases = hops.compactMap { id in hosts.first { $0.id == id.uuidString }?.alias }
                let block = AgentHost(machine, in: context).sshConfigBlock(jumpAliases: aliases)
                return aliases.count < hops.count ? "# Connects through a jump host hidden from agents.\n" + block : block
            }
            return .string(blocks.joined(separator: "\n\n"))

        case "run_command", "run_snippet":
            let machines = try server.targets(a)
            var command = a["command"]?.string ?? ""
            if name == "run_snippet" { command = try find(Snippet.self, a["snippet"], in: context, kind: "snippet", name: \.name).script }
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentToolError("The command is empty.") }
            let sudo = a["sudo"]?.bool ?? false
            let count = machines.count
            // A command on the user's read-only list (when they turned it on) runs without asking; it is still recorded.
            let readOnly = name == "run_command" && !sudo && AgentApproval.autoApprovesReadOnly && AgentApproval.isReadOnly(command)
            let title = "Run on \(count) machine\(count == 1 ? "" : "s")" + (sudo ? " with sudo" : "") + (readOnly ? " (read-only, not asked)" : "")
            try await server.requireApproval(AgentRequest(client: call.client, tool: name, title: title, detail: command,
                                                          hosts: machines.map(\.displayName), hostIDs: machines.map(\.id.uuidString),
                                                          sudo: sudo), for: call, ask: !readOnly)
            let job = AgentJob(command: command, hosts: machines.map(\.displayName))
            server.jobs.add(job)
            job.task = Task { @MainActor in
                let results = await AgentRunner.run(command: command, on: machines, sudo: sudo,
                                                    timeout: TimeInterval(max(a["timeout"]?.int ?? 300, 1)),
                                                    concurrency: a["concurrency"]?.int ?? 8, container: server.container) { result in
                    job.results.append(result)
                    server.progress(call, done: job.results.count, total: count,
                                    message: "\(result.host): " + (result.exitCode.map { "exit \($0)" } ?? result.error ?? "failed"))
                }
                job.results = results
                job.finished = Date()
                if call.deferred {
                    call.runs = results
                    let outcome = AgentActivityLog.outcome(of: results)
                    server.record(call, outcome: job.cancelled ? "cancelled; " + outcome : outcome)
                }
            }
            let deadline = Date().addingTimeInterval(TimeInterval(min(max(a["wait"]?.int ?? 120, 0), 3600)))
            while !job.isDone, Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            guard job.isDone else {
                call.deferred = true // the job records the activity when it ends
                guard case var .object(status) = job.status else { return job.status }
                status["note"] = "Still running. Call get_job with this job id to follow it, or cancel_job to stop it."
                return .object(status)
            }
            call.runs = job.results
            return .from(job.results)

        case "get_job":
            return try server.jobs.job(a["job"]?.string ?? "").status

        case "cancel_job":
            let job = try server.jobs.job(a["job"]?.string ?? "")
            if !job.isDone {
                job.cancelled = true
                job.task?.cancel()
            }
            return job.status

        case "add_host", "update_host":
            return try await saveHost(a, existing: name == "update_host" ? try server.machine(named: a["host"]?.string ?? "") : nil,
                                      server: server, call: call)

        case "remove_host":
            let machine = try server.machine(named: a["host"]?.string ?? "")
            let live = server.sessions?.sessionCount(for: machine) ?? 0
            try await server.requireApproval(AgentRequest(client: call.client, tool: name, title: "Remove machine \(machine.displayName)",
                                                          detail: "\(machine.displayName) (\(machine.host):\(machine.port))"
                                                              + (live > 0 ? "\nIts \(live) open session\(live == 1 ? "" : "s") will be closed." : ""),
                                                          hosts: [machine.displayName], hostIDs: [machine.id.uuidString]), for: call)
            server.sessions?.closeSessions(for: machine)
            KeychainService.delete(machine.passwordKey)
            context.delete(machine)
            try context.save()
            server.dashboard?.sync(with: server.machines)
            return ["removed": .string(machine.displayName)]

        case "list_identities":
            let identities = (try? context.fetch(FetchDescriptor<Identity>(sortBy: [SortDescriptor(\.name)]))) ?? []
            let machines = server.machines
            return .from(identities.map { AgentIdentity($0, machines: machines) })

        case "add_identity":
            return try await addIdentity(a, server: server, call: call)

        case "remove_identity":
            let identity = try find(Identity.self, a["identity"], in: context, kind: "identity", name: \.name)
            let users = server.machines.filter { $0.authMethod == .identity && $0.identity?.id == identity.id }.map(\.displayName)
            try await server.requireApproval(AgentRequest(client: call.client, tool: name, title: "Remove identity \(identity.name)",
                                                          detail: users.isEmpty ? "No machine uses it." : "Machines that lose their sign-in: \(users.joined(separator: ", "))",
                                                          hosts: users), for: call)
            KeychainService.delete(identity.passwordKey)
            context.delete(identity)
            try context.save()
            return ["removed": .string(identity.name)]

        case "list_snippets":
            var snippets = (try? context.fetch(FetchDescriptor<Snippet>(sortBy: [SortDescriptor(\.name)]))) ?? []
            if let query = a["query"]?.string?.lowercased(), !query.isEmpty {
                snippets = snippets.filter { [$0.name, $0.remark, $0.package?.name ?? ""].contains { $0.lowercased().contains(query) } }
            }
            return .from(snippets.map(AgentSnippet.init))

        case "add_snippet", "update_snippet":
            let existing = name == "update_snippet" ? try find(Snippet.self, a["snippet"], in: context, kind: "snippet", name: \.name) : nil
            let snippetName = a["name"]?.string ?? existing?.name ?? ""
            guard !snippetName.isEmpty else { throw AgentToolError("name is needed.") }
            if existing == nil, (a["script"]?.string ?? "").isEmpty { throw AgentToolError("script is needed.") }
            let changes = [a["name"]?.string.map { "name: \($0)" }, a["package"]?.string.map { "package: \($0)" },
                           a["comment"]?.string.map { "comment: \($0)" }, a["script"]?.string.map { "script:\n\($0)" }].compactMap { $0 }
            try await server.requireApproval(AgentRequest(client: call.client, tool: name,
                                                          title: existing == nil ? "Add snippet \(snippetName)" : "Change snippet \(existing!.name)",
                                                          detail: changes.joined(separator: "\n"), hosts: []), for: call)
            let snippet = existing ?? Snippet(name: snippetName)
            snippet.name = snippetName
            if let script = a["script"]?.string { snippet.script = script }
            if let comment = a["comment"]?.string { snippet.remark = comment }
            if let package = a["package"]?.string {
                snippet.package = package.isEmpty ? nil : findOrCreate(SnippetPackage.self, named: package, in: context, name: \.name) { SnippetPackage(name: $0) }
            }
            if existing == nil { context.insert(snippet) }
            try context.save()
            return .from(AgentSnippet(snippet))

        case "remove_snippet":
            let snippet = try find(Snippet.self, a["snippet"], in: context, kind: "snippet", name: \.name)
            try await server.requireApproval(AgentRequest(client: call.client, tool: name, title: "Remove snippet \(snippet.name)",
                                                          detail: snippet.script, hosts: []), for: call)
            context.delete(snippet)
            try context.save()
            return ["removed": .string(snippet.name)]

        case "list_port_forwards":
            let hidden = server.hiddenIDs
            let rules = ((try? context.fetch(FetchDescriptor<PortForwardingRule>(sortBy: [SortDescriptor(\.name)]))) ?? [])
                .filter { $0.machineID.map { !hidden.contains($0) } ?? true }
            let machines = server.machines
            return .array(rules.map { rule in
                guard case var .object(object) = JSONValue.from(AgentForward(rule, machines: machines)) else { return .null }
                object["state"] = server.sessions?.forwarding(for: rule).map { .string(forwardState($0.state)) } ?? "stopped"
                return .object(object)
            })

        case "add_port_forward":
            return try await addForward(a, server: server, call: call)

        case "start_port_forward", "stop_port_forward", "remove_port_forward":
            let rule = try find(PortForwardingRule.self, a["forward"], in: context, kind: "port forward", name: \.name)
            if let id = rule.machineID, server.hiddenIDs.contains(id) { throw AgentToolError("No port forward named \(a["forward"]?.string ?? "").") }
            let verb = ["start_port_forward": "Start", "stop_port_forward": "Stop", "remove_port_forward": "Remove"][name]!
            let machine = rule.machineID.flatMap { id in server.machines.first { $0.id == id } }
            try await server.requireApproval(AgentRequest(client: call.client, tool: name, title: "\(verb) port forward \(rule.name)",
                                                          detail: describe(rule, through: machine), hosts: machine.map { [$0.displayName] } ?? [],
                                                          hostIDs: machine.map { [$0.id.uuidString] } ?? []), for: call)
            guard let sessions = server.sessions else { throw AgentToolError("SwiftPulse is not ready to run port forwards.") }
            switch name {
            case "start_port_forward":
                guard let session = sessions.startForwarding(rule) else { throw AgentToolError("The port forward's machine no longer exists.") }
                return ["forward": .string(rule.name), "state": .string(forwardState(session.state))]
            case "stop_port_forward":
                if let running = sessions.forwarding(for: rule) { sessions.close(running) }
                return ["forward": .string(rule.name), "state": "stopped"]
            default:
                if let running = sessions.forwarding(for: rule) { sessions.close(running) }
                context.delete(rule)
                try context.save()
                return ["removed": .string(rule.name)]
            }

        case "list_containers":
            let session = try await dockerSession(a, server: server)
            let inventory = session.inventory
            return .array(inventory.containers.map { container in
                let stats = inventory.stats(for: container)
                // No command or labels: they can carry secrets, and this tool asks no one.
                return [
                    "id": .string(container.shortID), "name": .string(container.name), "image": .string(container.image),
                    "state": .string(container.state), "status": .string(container.status), "ports": .array(container.ports.map { .string($0) }),
                    "project": container.project.isEmpty ? .null : .string(container.project),
                    "service": container.service.isEmpty ? .null : .string(container.service),
                    "cpuPercent": stats.map { .number(($0.cpu * 10).rounded() / 10) } ?? .null,
                    "memoryUsedBytes": stats.map { .number(Double($0.memoryUsed)) } ?? .null,
                ]
            })

        case "container_logs":
            let session = try await dockerSession(a, server: server)
            let reference = a["container"]?.string ?? ""
            guard let container = session.inventory.containers.first(where: {
                $0.name == reference || $0.id.hasPrefix(reference) && reference.count >= 4
            }) else { throw AgentToolError("No container \(reference) on this machine. list_containers shows them.") }
            let lines = min(max(a["lines"]?.int ?? 200, 1), 2000)
            return .string(AgentRunner.tail(Data(await session.logs(container, lines: lines).utf8)).0)

        case "get_activity":
            let hostID = try a["host"]?.string.flatMap { $0.isEmpty ? nil : try server.machine(named: $0).id.uuidString }
            let hidden = Set(server.hiddenIDs.map(\.uuidString))
            let entries = AgentActivityLog.entries(hostID: hostID, limit: (a["limit"]?.int ?? 50) + hidden.count * 10, in: context)
                .filter { $0.hostIDs.allSatisfy { !hidden.contains($0) } } // nothing about a hidden machine, not even its name
            return .from(entries.prefix(max(a["limit"]?.int ?? 50, 1)).map(AgentActivityRecord.init))

        case "log_activity":
            let machines = try (a["hosts"]?.strings ?? []).map(server.machine(named:))
            guard !machines.isEmpty else { throw AgentToolError("Name the machines in hosts.") }
            let summary = a["summary"]?.string ?? ""
            guard !summary.isEmpty else { throw AgentToolError("summary is needed.") }
            let commands = (a["commands"]?.strings ?? []).map { "$ " + $0 }.joined(separator: "\n")
            let detail = [a["details"]?.string ?? "", commands].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let entry = AgentActivity(client: call.client, tool: "report", hostIDs: machines.map(\.id.uuidString),
                                      hostNames: machines.map(\.displayName), summary: summary, detail: detail, outcome: "reported")
            AgentActivityLog.add(entry, task: call.task, in: context)
            return ["logged": .string(summary)]

        default:
            throw AgentToolError("Unknown tool \(name). tools/list shows them.")
        }
    }

    // MARK: - Machines

    private static func saveHost(_ a: JSONValue, existing: Machine?, server: MCPServer, call: AgentCall) async throws -> JSONValue {
        let context = server.context
        let address = a["address"]?.string?.trimmingCharacters(in: .whitespaces) ?? existing?.host ?? ""
        guard !address.isEmpty else { throw AgentToolError("address is needed.") }
        let identity = try a["identity"]?.string.map { try find(Identity.self, .string($0), in: context, kind: "identity", name: \.name) }
        let key = try a["key"]?.string.map { try find(SSHKey.self, .string($0), in: context, kind: "SSH key", name: \.name) }
        let password = a["password"]?.string
        let noAuthentication = a["auth"]?.string == "none"
        let jumps = try a["jump_hosts"].map { try $0.strings.map(server.machine(named:)) }
        if existing == nil, identity == nil, key == nil, (password ?? "").isEmpty, !noAuthentication {
            throw AgentToolError("Give the machine a way to sign in: identity, key, password, or auth: \"none\".")
        }
        if let existing, jumps?.contains(where: { $0.id == existing.id }) == true { throw AgentToolError("A machine can't be its own jump host.") }

        let name = a["name"]?.string ?? existing?.name ?? ""
        let label = name.isEmpty ? address : name
        var lines: [String] = []
        if a["address"] != nil || a["port"] != nil || existing == nil { lines.append("address: \(address):\(a["port"]?.int ?? existing?.port ?? 22)") }
        if a["name"] != nil { lines.append("name: \(name)") }
        if let identity { lines.append("identity: \(identity.name) (\(identity.username))") }
        if let user = a["username"]?.string { lines.append("username: \(user)") }
        if let key { lines.append("SSH key: \(key.name)") }
        if password != nil { lines.append("password: set (not shown)") }
        if noAuthentication { lines.append("sign-in: none (the server trusts the connection)") }
        if let command = a["proxy_command"]?.string { lines.append("ProxyCommand: \(command.isEmpty ? "none" : command)") }
        if let group = a["group"]?.string { lines.append("group: \(group)") }
        if let tags = a["tags"]?.strings, a["tags"] != nil { lines.append("tags: \(tags.joined(separator: ", "))") }
        if let jumps { lines.append("jump hosts: \(jumps.isEmpty ? "none" : jumps.map(\.displayName).joined(separator: " → "))") }
        if let comment = a["comment"]?.string { lines.append("comment: \(comment)") }
        if let dashboard = a["dashboard"]?.bool { lines.append("dashboard: \(dashboard ? "on" : "off")") }
        try await server.requireApproval(AgentRequest(client: call.client, tool: existing == nil ? "add_host" : "update_host",
                                                      title: existing == nil ? "Add machine \(label)" : "Change machine \(existing!.displayName)",
                                                      detail: lines.joined(separator: "\n"), hosts: [label],
                                                      hostIDs: existing.map { [$0.id.uuidString] } ?? []), for: call)

        let machine = existing ?? Machine(name: name, host: address, port: 22)
        machine.host = address
        machine.name = name
        if let port = a["port"]?.int { machine.port = port }
        if let identity {
            machine.authMethod = .identity
            machine.identity = identity
        } else if noAuthentication {
            machine.authMethod = .noAuthentication
            machine.username = a["username"]?.string ?? (machine.username.isEmpty ? "root" : machine.username)
        } else if key != nil || password != nil || a["username"] != nil {
            if existing == nil || machine.authMethod == .identity { machine.authMethod = .passwordOrKey }
            machine.username = a["username"]?.string ?? (machine.username.isEmpty ? "root" : machine.username)
            if let key { machine.sshKey = key }
        }
        if let group = a["group"]?.string {
            machine.group = group.isEmpty ? nil : findOrCreate(MachineGroup.self, named: group, in: context, name: \.name) { MachineGroup(name: $0) }
        }
        if a["tags"] != nil { machine.tags = a["tags"]?.strings ?? [] }
        if let comment = a["comment"]?.string { machine.remark = comment }
        if let command = a["proxy_command"]?.string { machine.proxyCommand = command.trimmingCharacters(in: .whitespaces) }
        if let dashboard = a["dashboard"]?.bool { machine.showInDashboard = dashboard }
        if let jumps {
            machine.useJumpHost = !jumps.isEmpty
            machine.jumpHostIDs = jumps.map(\.id)
        }
        if existing == nil { context.insert(machine) }
        if let password { KeychainService.set(password.isEmpty ? nil : password, for: machine.passwordKey) }
        try context.save()
        server.dashboard?.sync(with: server.machines)
        return .from(AgentHost(machine, in: context))
    }

    // MARK: - Identities

    private static func addIdentity(_ a: JSONValue, server: MCPServer, call: AgentCall) async throws -> JSONValue {
        let context = server.context
        let name = a["name"]?.string ?? "", username = a["username"]?.string ?? ""
        guard !name.isEmpty, !username.isEmpty else { throw AgentToolError("name and username are needed.") }
        let generate = a["generate"]?.bool ?? false
        let privateKey = a["private_key"]?.string?.nilIfEmpty
        let password = a["password"]?.string?.nilIfEmpty
        guard generate || privateKey != nil || password != nil else { throw AgentToolError("Give generate: true, a private_key or a password.") }
        guard !(generate && privateKey != nil) else { throw AgentToolError("Give generate: true or a private_key, not both.") }

        var keyType: SSHKeyType?
        if let privateKey {
            do { try OpenSSHPrivateKey.validate(privateKey) } catch { throw AgentToolError("private_key can't be used: \(error.localizedDescription)") }
            let pem = PKCS1Converter.isPKCS1(privateKey) ? (try? PKCS1Converter.toOpenSSH(privateKey)) ?? privateKey : privateKey
            keyType = SSHKeyGenerator.type(fromPublicKey: a["public_key"]?.string ?? "")
                ?? (try? OpenSSHPrivateKey.keyType(pem)).flatMap { SSHKeyGenerator.type(fromPublicKey: $0) }
        }
        let lines = ["username: \(username)",
                     generate ? "SSH key: generate a new Ed25519 key" : privateKey != nil ? "SSH key: import a \(keyType?.title ?? "private") key (not shown)" : nil,
                     password != nil ? "password: set (not shown)" : nil].compactMap { $0 }
        try await server.requireApproval(AgentRequest(client: call.client, tool: "add_identity", title: "Add identity \(name)",
                                                      detail: lines.joined(separator: "\n"), hosts: []), for: call)

        let identity = Identity(name: name, username: username)
        if generate || privateKey != nil {
            let key: SSHKey
            if generate {
                let pair = try SSHKeyGenerator.generate(.ed25519, comment: name)
                key = SSHKey(name: name, keyType: .ed25519, publicKey: pair.publicKey)
                KeychainService.set(pair.privateKey, for: key.privateKeyKey)
            } else {
                key = SSHKey(name: name, keyType: keyType ?? .ed25519, publicKey: a["public_key"]?.string ?? "")
                KeychainService.set(privateKey, for: key.privateKeyKey)
                if let passphrase = a["passphrase"]?.string?.nilIfEmpty {
                    key.hasPassphrase = true
                    KeychainService.set(passphrase, for: key.passphraseKey)
                }
            }
            context.insert(key)
            identity.sshKey = key
        }
        if let password {
            identity.hasPassword = true
            KeychainService.set(password, for: identity.passwordKey)
        }
        context.insert(identity)
        try context.save()
        return .from(AgentIdentity(identity, machines: server.machines))
    }

    // MARK: - Port forwards

    private static func addForward(_ a: JSONValue, server: MCPServer, call: AgentCall) async throws -> JSONValue {
        let context = server.context
        let machine = try server.machine(named: a["host"]?.string ?? "")
        guard let mode = (a["mode"]?.string).flatMap(ForwardingMode.init(rawValue:)) else { throw AgentToolError("mode is local, remote or dynamic.") }
        guard let localPort = a["local_port"]?.int, (1...65535).contains(localPort) else { throw AgentToolError("local_port is needed (1-65535).") }
        let targetPort = a["target_port"]?.int ?? 0
        if mode != .dynamic, !(1...65535).contains(targetPort) { throw AgentToolError("target_port is needed (1-65535).") }

        let rule = PortForwardingRule(name: a["name"]?.string ?? "\(machine.displayName) \(localPort)")
        rule.mode = mode
        rule.machineID = machine.id
        rule.localHost = a["local_host"]?.string ?? "127.0.0.1"
        rule.localPort = localPort
        rule.targetHost = a["target_host"]?.string ?? "127.0.0.1"
        rule.targetPort = mode == .dynamic ? 0 : targetPort
        rule.autoStart = a["auto_start"]?.bool ?? false
        let start = a["start"]?.bool ?? false
        try await server.requireApproval(AgentRequest(client: call.client, tool: "add_port_forward",
                                                      title: "Add port forward \(rule.name)" + (start ? " and start it" : ""),
                                                      detail: describe(rule, through: machine), hosts: [machine.displayName],
                                                      hostIDs: [machine.id.uuidString]), for: call)
        context.insert(rule)
        try context.save()
        var state = "stopped"
        if start, let session = server.sessions?.startForwarding(rule) { state = forwardState(session.state) }
        guard case var .object(object) = JSONValue.from(AgentForward(rule, machines: server.machines)) else { return .null }
        object["state"] = .string(state)
        return .object(object)
    }

    private static func describe(_ rule: PortForwardingRule, through machine: Machine?) -> String {
        let via = machine?.displayName ?? "a removed machine"
        switch rule.mode {
        case .local: return "local: \(rule.localHost):\(rule.localPort) on this Mac → \(rule.targetHost):\(rule.targetPort) via \(via)"
        case .remote: return "remote: port \(rule.localPort) on \(via) → \(rule.targetHost):\(rule.targetPort) from this Mac"
        case .dynamic: return "dynamic: SOCKS5 proxy on \(rule.localHost):\(rule.localPort), through \(via)"
        }
    }

    private static func forwardState(_ state: ForwardingSession.State) -> String {
        switch state {
        case .connecting: "connecting"
        case .running: "running"
        case .stopped(let why): why.map { "stopped: \($0)" } ?? "stopped"
        }
    }

    // MARK: - Docker

    /// The machine's Docker session, connected and loaded; waits up to 20 s for the first load.
    private static func dockerSession(_ a: JSONValue, server: MCPServer) async throws -> DockerSession {
        let machine = try server.machine(named: a["host"]?.string ?? "")
        guard let docker = server.docker, let dashboard = server.dashboard else { throw AgentToolError("SwiftPulse is not ready to read Docker.") }
        let session = docker.session(for: machine, dashboard: dashboard)
        for _ in 0..<40 where !session.isReady && session.error == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let error = session.error { throw AgentToolError("Docker on \(machine.displayName): \(error)") }
        guard session.isReady else { throw AgentToolError("Docker on \(machine.displayName) is still loading; ask again shortly.") }
        return session
    }

    // MARK: - Lookups

    /// A model by id or (case-insensitive, unique) name.
    static func find<T: PersistentModel>(_ type: T.Type, _ reference: JSONValue?, in context: ModelContext, kind: String,
                                         name: KeyPath<T, String>) throws -> T where T.ID == UUID {
        let text = reference?.string ?? ""
        guard !text.isEmpty else { throw AgentToolError("Name the \(kind).") }
        let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
        if let id = UUID(uuidString: text), let match = all.first(where: { $0.id == id }) { return match }
        let matches = all.filter { $0[keyPath: name].caseInsensitiveCompare(text) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw AgentToolError("\(matches.count) of them are named \(text); use the \(kind)'s id.") }
        throw AgentToolError("No \(kind) named \(text).")
    }

    static func findOrCreate<T: PersistentModel>(_ type: T.Type, named text: String, in context: ModelContext,
                                                 name: KeyPath<T, String>, make: (String) -> T) -> T {
        let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
        if let match = all.first(where: { $0[keyPath: name].caseInsensitiveCompare(text) == .orderedSame }) { return match }
        let created = make(text)
        context.insert(created)
        return created
    }

    // MARK: - Metrics

    /// The dashboard's live readings for a machine, or why there are none.
    static func metrics(for machine: Machine, dashboard: DashboardStore?) -> JSONValue {
        guard let dashboard, machine.showInDashboard else {
            return ["state": "not_monitored", "note": "Not on the dashboard, so SwiftPulse has no live metrics for it."]
        }
        // The dashboard polls these machines anyway; this starts it when its view hasn't yet (idempotent).
        let monitor = dashboard.monitor(for: machine)
        monitor.start()
        monitor.demand()
        var state: JSONValue
        switch monitor.state {
        case .idle: state = "idle"
        case .connecting: state = "connecting"
        case .online: state = "online"
        case .offline(let why): state = .string("offline: \(why)")
        }
        guard let status = monitor.status else { return ["state": state, "note": "No reading yet; ask again in a few seconds."] }
        let snap = status.snapshot
        func round(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
        func bytes(_ value: Int64) -> JSONValue { .number(Double(value)) }
        let traffic = snap.traffic
        return [
            "state": state,
            "latencyMs": monitor.latencyMs.map { .number(Double($0)) } ?? .null,
            "updated": .string(ISO8601DateFormatter().string(from: snap.takenAt)),
            "hostname": .string(snap.hostname), "os": .string(snap.osName), "kernel": .string(snap.kernel),
            "uptimeSeconds": round(snap.uptime), "cores": .number(Double(snap.coreCount)),
            "cpu": ["percent": round(status.cpu.total), "user": round(status.cpu.user), "system": round(status.cpu.system),
                    "iowait": round(status.cpu.iowait), "steal": round(status.cpu.steal)],
            "load": .array(snap.load.map(round)),
            "memory": ["totalBytes": bytes(snap.memTotal), "usedBytes": bytes(status.memUsed), "percent": round(status.memPercent),
                       "cachedBytes": bytes(snap.memCached)],
            "swap": ["totalBytes": bytes(snap.swapTotal), "usedBytes": bytes(status.swapUsed)],
            "disks": .array(snap.disks.map { disk in
                ["mount": .string(disk.mount), "filesystem": .string(disk.filesystem), "totalBytes": bytes(disk.total),
                 "usedBytes": bytes(disk.used), "percent": round(disk.total > 0 ? Double(disk.used) / Double(disk.total) * 100 : 0)]
            }),
            "network": ["interfaces": .array(snap.physicalInterfaces.map { .string($0) }), "rxBytesPerSecond": round(status.network.rx),
                        "txBytesPerSecond": round(status.network.tx),
                        "rxBytesSinceBoot": bytes(traffic.rx), "txBytesSinceBoot": bytes(traffic.tx)],
            "diskIO": ["readBytesPerSecond": round(status.diskIO.rx), "writeBytesPerSecond": round(status.diskIO.tx),
                       "devices": .array(status.devices.map { d in
                           ["name": .string(d.name), "readBytesPerSecond": round(d.read), "writeBytesPerSecond": round(d.write),
                            "iops": round(d.iops), "awaitMs": round(d.awaitMs)]
                       })],
            "tcp": snap.tcp.map { tcp in
                ["established": bytes(tcp.established), "failedAttempts": bytes(tcp.failedAttempts),
                 "retransmitPercent": status.tcpRetransmitPercent.map(round) ?? .null]
            } ?? .null,
            "temperatureC": snap.temperatureC.map(round) ?? .null,
            // The process name only (comm), never its arguments, which can hold secrets.
            "topProcesses": .array(snap.processes.prefix(10).map { process in
                ["pid": .number(Double(process.pid)), "user": .string(process.user), "cpuPercent": round(process.cpu),
                 "memPercent": round(process.mem), "command": .string(process.command)]
            }),
        ]
    }
}
