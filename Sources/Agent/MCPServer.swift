import Foundation
import SwiftData

/// One client connection to the socket, and what it said it is in `initialize`.
final class MCPSession: @unchecked Sendable {
    let id = UUID()
    var clientName = "Agent"
    /// Grants the user gave this connection (see `AgentGrant`).
    var allowedForSession = false
    var allowedUntil: Date?
    /// Set when the connection closes; requests it left waiting for approval are then denied.
    var isDisconnected = false
    /// Writes a message to this client outside a reply (progress notifications); set by the socket.
    var send: ((String) -> Void)?
}

/// One tool call: what it asked approval for and what it ran, so the activity log records exactly this call
/// even while other calls are in flight.
@MainActor
final class AgentCall {
    let session: MCPSession
    let task: String?
    var request: AgentRequest?
    var runs: [AgentRunResult]?
    /// The client's token for progress notifications, when it asked for them.
    var progressToken: JSONValue?
    /// The call handed its work to a background job, which records the activity when it ends.
    var deferred = false

    init(session: MCPSession, task: String?) {
        self.session = session
        self.task = task
    }

    var client: String { session.clientName }
}

/// A connected client, for Settings.
struct AgentClient: Identifiable, Equatable {
    let id: UUID
    var name: String
    var lastSeen: Date
}

/// SwiftPulse's MCP server: agents list and manage machines, identities, snippets and port forwards, read live
/// metrics and Docker state, and run commands through SwiftPulse. Secrets only go in: every reply is built from
/// the `Agent*` projections. Anything that changes something or runs a command waits for the user's approval.
/// JSON-RPC 2.0, one message per line, as on MCP's stdio transport.
@MainActor @Observable
final class MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let dashboard: DashboardStore?
    @ObservationIgnored let sessions: SessionManager?
    @ObservationIgnored let docker: DockerStore?
    /// Asks the user unless the session has a grant; replaced in tests.
    @ObservationIgnored var approve: (AgentRequest, MCPSession) async -> Bool = AgentApproval.decide
    @ObservationIgnored let jobs = AgentJobs()
    private(set) var clients: [AgentClient] = []

    init(container: ModelContainer, dashboard: DashboardStore?, sessions: SessionManager? = nil, docker: DockerStore? = nil) {
        self.container = container
        self.dashboard = dashboard
        self.sessions = sessions
        self.docker = docker
    }

    var context: ModelContext { container.mainContext }

    static let instructions = """
    SwiftPulse holds the user's SSH machines. Use list_hosts to see them, get_metrics for live load, and run_command \
    to run a shell command on one or more machines: the user approves it first, and SwiftPulse signs in with its own \
    saved credentials, so you never need a password or key. The add_/update_/remove_ tools manage machines, \
    identities (SSH keys), snippets and port forwards; passwords and private keys can be set but are never \
    returned. Prefer generate: true in add_identity and give the user the public key. Give every call that changes \
    something a task: a short name for the goal it serves ("Install nginx"), the same for every step toward that \
    goal, so the steps are kept as one entry in the machine's history. Before working on a machine, call \
    get_activity for it to see what earlier agents did. Whenever you change a machine by other means (your own \
    ssh, scp, a deploy tool), call log_activity with what you did. A run that outlasts its wait (120 s by default) \
    returns a job id; follow it with get_job rather than running it again. A machine whose host key SwiftPulse hasn't \
    verified fails with host_key_unverified; ask the user to connect to it once from SwiftPulse's terminal.
    """

    // MARK: - Clients

    /// Called by the socket when a client goes away.
    func disconnected(_ session: MCPSession) {
        session.isDisconnected = true
        AgentApproval.cancelRequests(from: session)
        clients.removeAll { $0.id == session.id }
    }

    private func seen(_ session: MCPSession) {
        if let index = clients.firstIndex(where: { $0.id == session.id }) {
            clients[index].name = session.clientName
            clients[index].lastSeen = Date()
        } else {
            clients.append(AgentClient(id: session.id, name: session.clientName, lastSeen: Date()))
        }
    }

    // MARK: - JSON-RPC

    /// Handles one JSON-RPC message; nil for a notification, which gets no reply.
    func handle(_ line: String, session: MCPSession) async -> String? {
        guard let data = line.data(using: .utf8), let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = message
        else { return Self.error(id: .null, code: -32700, message: "Parse error") }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            return id == nil ? nil : Self.error(id: id!, code: -32600, message: "Invalid request")
        }
        let params = message["params"] ?? [:]
        defer { seen(session) }

        let result: Result<JSONValue, RPCError>
        switch method {
        case "initialize":
            if let name = params["clientInfo"]?["name"]?.string, !name.isEmpty { session.clientName = name }
            let requested = params["protocolVersion"]?.string ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            result = .success([
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false], "prompts": ["listChanged": false]],
                "serverInfo": ["name": "swiftpulse", "version": .string(Self.appVersion)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            result = .success([:])
        case "tools/list":
            result = .success(["tools": .array(AgentTools.definitions)])
        case "tools/call":
            let name = params["name"]?.string ?? ""
            result = .success(await callTool(name, arguments: params["arguments"] ?? [:], session: session,
                                             progressToken: params["_meta"]?["progressToken"]))
        case "prompts/list":
            result = .success(["prompts": .array(AgentPrompts.list)])
        case "prompts/get":
            if let prompt = AgentPrompts.get(params["name"]?.string ?? "", arguments: params["arguments"] ?? [:]) {
                result = .success(prompt)
            } else {
                result = .failure(RPCError(code: -32602, message: "Unknown prompt \(params["name"]?.string ?? "")"))
            }
        case "resources/list":
            result = .success(["resources": [
                ["uri": "swiftpulse://hosts", "name": "Machines", "description": "Every machine in SwiftPulse, without secrets",
                 "mimeType": "application/json"],
            ]])
        case "resources/read":
            let uri = params["uri"]?.string ?? ""
            if uri == "swiftpulse://hosts" {
                result = .success(["contents": [[
                    "uri": "swiftpulse://hosts", "mimeType": "application/json",
                    "text": .string(JSONValue.from(hosts(matching: [:])).encodedString(pretty: true)),
                ]]])
            } else {
                result = .failure(RPCError(code: -32002, message: "Unknown resource \(uri)"))
            }
        default:
            result = method.hasPrefix("notifications/") ? .success(.null)
                : .failure(RPCError(code: -32601, message: "Method not found: \(method)"))
        }
        guard let id else { return nil } // a notification
        switch result {
        case let .success(value):
            return (["jsonrpc": "2.0", "id": id, "result": value] as JSONValue).encodedString()
        case let .failure(error):
            return Self.error(id: id, code: error.code, message: error.message)
        }
    }

    struct RPCError: Error {
        let code: Int
        let message: String
    }

    static func error(id: JSONValue, code: Int, message: String) -> String {
        (["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]] as JSONValue).encodedString()
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Tool calls

    /// A tool's reply: its JSON as text, or an error the agent reads. Every call that asked for approval goes into
    /// the activity of the machines it concerns, whatever its outcome.
    func callTool(_ name: String, arguments: JSONValue, session: MCPSession, progressToken: JSONValue? = nil) async -> JSONValue {
        let call = AgentCall(session: session, task: arguments["task"]?.string)
        call.progressToken = progressToken
        do {
            let output = try await AgentTools.call(name, arguments: arguments, server: self, call: call)
            if !call.deferred { record(call, outcome: call.runs.map(AgentActivityLog.outcome(of:)) ?? "ok") }
            return ["content": [["type": "text", "text": .string(output.encodedString(pretty: true))]], "isError": false]
        } catch {
            let toolError = error as? AgentToolError
            let message = toolError?.message ?? error.localizedDescription
            record(call, outcome: toolError?.declined == true ? "declined" : message)
            return ["content": [["type": "text", "text": .string(message)]], "isError": true]
        }
    }

    /// Asks the user (or uses a standing grant); throws when refused. The request is what the activity records.
    func requireApproval(_ request: AgentRequest, for call: AgentCall, ask: Bool = true) async throws {
        var request = request
        request.task = call.task
        call.request = request
        guard ask else { return }
        guard await approve(request, call.session) else {
            throw AgentToolError("Declined by the user: \(request.title).", declined: true)
        }
    }

    /// Sends `notifications/progress` for a call whose client asked for it.
    func progress(_ call: AgentCall, done: Int, total: Int, message: String) {
        guard let token = call.progressToken, let send = call.session.send else { return }
        send((["jsonrpc": "2.0", "method": "notifications/progress",
               "params": ["progressToken": token, "progress": .number(Double(done)), "total": .number(Double(total)),
                          "message": .string(message)]] as JSONValue).encodedString())
    }

    func record(_ call: AgentCall, outcome: String) {
        guard let request = call.request else { return }
        let results = (call.runs ?? []).map {
            AgentActivity.Result(host: $0.host, exitCode: $0.exitCode, tail: String(($0.error ?? $0.output).suffix(2000)))
        }
        let entry = AgentActivity(client: request.client, tool: request.tool, hostIDs: request.hostIDs, hostNames: request.hosts,
                                  summary: request.title, detail: request.detail, outcome: outcome, results: results)
        AgentActivityLog.add(entry, task: call.task, in: context)
    }

    // MARK: - Machines

    /// The machines agents may see: every one not hidden from them. Every tool goes through this.
    var machines: [Machine] {
        let all = (try? context.fetch(FetchDescriptor<Machine>(sortBy: [SortDescriptor(\.name)]))) ?? []
        return all.filter { !$0.hiddenFromAgents }
    }

    /// Ids of the machines hidden from agents.
    var hiddenIDs: Set<UUID> {
        Set(((try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.hiddenFromAgents }))) ?? []).map(\.id))
    }

    /// Every machine, or those a filter names: query, group, tag.
    func hosts(matching arguments: JSONValue) -> [AgentHost] {
        var list = machines
        if let query = arguments["query"]?.string?.lowercased(), !query.isEmpty {
            list = list.filter {
                [$0.displayName, $0.host, $0.remark, $0.group?.name ?? ""].contains { $0.lowercased().contains(query) }
                    || $0.tags.contains { $0.lowercased().contains(query) }
            }
        }
        if let group = arguments["group"]?.string, !group.isEmpty {
            list = list.filter { $0.group?.name.caseInsensitiveCompare(group) == .orderedSame }
        }
        if let tag = arguments["tag"]?.string, !tag.isEmpty {
            list = list.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        }
        return list.map { AgentHost($0, in: context) }
    }

    /// A machine by id, name or address.
    func machine(named reference: String) throws -> Machine {
        let all = machines
        if let id = UUID(uuidString: reference), let machine = all.first(where: { $0.id == id }) { return machine }
        let matches = all.filter {
            $0.displayName.caseInsensitiveCompare(reference) == .orderedSame || $0.host.caseInsensitiveCompare(reference) == .orderedSame
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw AgentToolError("\(matches.count) machines match \(reference); use its id from list_hosts.") }
        throw AgentToolError("No machine named \(reference). list_hosts shows them.")
    }

    /// The machines a run targets: hosts (ids, names or addresses), a group, a tag, or all; each once.
    func targets(_ arguments: JSONValue) throws -> [Machine] {
        let spec = arguments["targets"] ?? arguments
        let all = machines
        var result: [Machine] = []
        if spec["all"]?.bool == true { result = all }
        for reference in spec["hosts"]?.strings ?? [] { result.append(try machine(named: reference)) }
        if let group = spec["group"]?.string, !group.isEmpty {
            let members = all.filter { $0.group?.name.caseInsensitiveCompare(group) == .orderedSame }
            guard !members.isEmpty else { throw AgentToolError("No machines in group \(group).") }
            result += members
        }
        if let tag = spec["tag"]?.string, !tag.isEmpty {
            let tagged = all.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            guard !tagged.isEmpty else { throw AgentToolError("No machines tagged \(tag).") }
            result += tagged
        }
        var seen = Set<UUID>()
        result = result.filter { seen.insert($0.id).inserted }
        guard !result.isEmpty else { throw AgentToolError("Name the machines: targets {hosts: [...]}, {group}, {tag} or {all: true}.") }
        return result
    }
}

/// What an agent is told went wrong. Always English: agents read it and act on it.
struct AgentToolError: Error {
    let message: String
    /// The user said no, as opposed to something failing.
    var declined = false
    init(_ message: String, declined: Bool = false) {
        self.message = message
        self.declined = declined
    }
}
