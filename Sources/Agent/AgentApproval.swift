import AppKit
import SwiftUI
import UserNotifications

/// One action an agent wants to take, as the approval shows it.
struct AgentRequest: Sendable {
    let client: String
    let tool: String
    /// "Run on 3 machines", "Add machine web-2".
    let title: String
    /// The command, or what changes.
    let detail: String
    let hosts: [String]
    /// The machines' ids, for their activity.
    var hostIDs: [String] = []
    /// The goal the action serves, as the agent named it ("Install nginx").
    var task: String?
    var sudo = false
}

/// The user's answer, and how long it lasts.
enum AgentGrant: Equatable {
    case deny, once
    /// This connection only: another process can't claim it, whatever name it gives.
    case session
    /// This connection, for an hour.
    case hour
    /// Every connection that calls itself this client, until revoked in Settings. Names are self-reported,
    /// which is why this is the one choice marked as risky.
    case always
}

/// Decides whether an agent may act: a standing grant, or the user's answer to a panel. One panel at a time;
/// requests that arrive meanwhile wait their turn.
@MainActor
enum AgentApproval {
    static let alwaysKey = "mcpAlwaysAllowed"

    static var alwaysAllowed: [String] { (UserDefaults.standard.stringArray(forKey: alwaysKey) ?? []).sorted() }

    static func revokeAlways(_ client: String) {
        UserDefaults.standard.set(alwaysAllowed.filter { $0 != client }, forKey: alwaysKey)
    }

    // MARK: - Read-only commands

    static let autoApproveKey = "mcpAutoApproveReadOnly"
    static let readOnlyCommandsKey = "mcpReadOnlyCommands"
    /// Commands that only read, in every form their arguments can take (an entry also matches with any arguments
    /// after it). Not `hostname` or `date` (as root they set the name or the clock), not `ss` (`-K` kills
    /// sockets), not `journalctl` (`--vacuum-*` deletes logs), not `cat <file>` (more files can follow it).
    static let defaultReadOnlyCommands = [
        "uname", "uptime", "df", "free", "whoami", "id", "nproc", "lsblk", "ps",
        "systemctl status", "systemctl is-active", "systemctl is-enabled", "systemctl list-units", "docker ps",
    ].joined(separator: "\n")

    static var autoApprovesReadOnly: Bool { UserDefaults.standard.bool(forKey: autoApproveKey) }

    static var readOnlyCommands: [String] {
        (UserDefaults.standard.string(forKey: readOnlyCommandsKey) ?? defaultReadOnlyCommands)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether `command` is one of `allowed`, alone or with arguments. Anything a shell would treat specially
    /// (a second command, a pipe, a redirect, a substitution, a glob, quoting) disqualifies it, so an allowed
    /// prefix can't smuggle in something else.
    static func isReadOnly(_ command: String, allowed: [String]? = nil) -> Bool {
        let allowed = allowed ?? readOnlyCommands
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, command.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|`$<>(){}[]\\*?~!#'\"\n\r\t")) == nil
        else { return false }
        return allowed.contains { command == $0 || command.hasPrefix($0 + " ") }
    }

    // MARK: - Grants

    /// Whether `session` may act without asking now.
    static func isGranted(_ client: String, session: MCPSession, now: Date = Date()) -> Bool {
        alwaysAllowed.contains(client) || session.allowedForSession || (session.allowedUntil ?? .distantPast) > now
    }

    /// Records a grant on the session (or for the client), and says whether this request may go ahead.
    static func apply(_ grant: AgentGrant, client: String, session: MCPSession, now: Date = Date()) -> Bool {
        switch grant {
        case .deny: return false
        case .once: break
        case .session: session.allowedForSession = true
        case .hour: session.allowedUntil = now.addingTimeInterval(3600)
        case .always: UserDefaults.standard.set(Array(Set(alwaysAllowed + [client])), forKey: alwaysKey)
        }
        return true
    }

    /// The default `MCPServer.approve`.
    static func decide(_ request: AgentRequest, session: MCPSession) async -> Bool {
        if isGranted(request.client, session: session) { return true }
        return apply(await ask(request, session: session), client: request.client, session: session)
    }

    // MARK: - The panel

    private static var busy = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []
    private static var panel: NSPanel?
    /// The session whose request is on screen, and how to close the panel with an answer.
    private static var showing: (session: ObjectIdentifier, answer: (AgentGrant) -> Void)?

    /// The agent disconnected: its request on screen is denied and closed. Requests it left in the queue are denied
    /// when their turn comes (see `ask`), so nothing can be approved for a client that is no longer listening.
    static func cancelRequests(from session: MCPSession) {
        if let showing, showing.session == ObjectIdentifier(session) { showing.answer(.deny) }
    }

    /// A notification for a request that arrives while the user is in another app: the panel waits behind it.
    private static func notify(_ request: AgentRequest) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(request.client) wants to: \(request.title)"
            content.body = (request.task.map { "For: \($0)\n" } ?? "") + String(request.detail.prefix(200))
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-approval", content: content, trigger: nil))
        }
    }

    private static func ask(_ request: AgentRequest, session: MCPSession) async -> AgentGrant {
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        if session.isDisconnected { return .deny }
        return await withCheckedContinuation { continuation in
            let shown = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled],
                                backing: .buffered, defer: false)
            var answered = false
            let answer: (AgentGrant) -> Void = { grant in
                guard !answered else { return }
                answered = true
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["agent-approval"])
                shown.orderOut(nil)
                panel = nil
                showing = nil
                continuation.resume(returning: grant)
            }
            showing = (ObjectIdentifier(session), answer)
            let view = AgentApprovalView(request: request, decide: answer)
            shown.title = "Agent Request"
            shown.contentView = NSHostingView(rootView: view)
            shown.hidesOnDeactivate = false
            shown.level = .floating
            shown.center()
            panel = shown
            let inBackground = !NSApp.isActive
            NSApp.activate()
            shown.makeKeyAndOrderFront(nil)
            NSApp.requestUserAttention(.criticalRequest)
            if inBackground { notify(request) }
        }
    }
}

/// What the agent wants, and the choices. There is no default button, so Return never allows anything;
/// Escape denies.
struct AgentApprovalView: View {
    let request: AgentRequest
    let decide: (AgentGrant) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text("\(request.client) wants to: \(request.title)").font(.headline)
                if request.sudo {
                    Text("sudo").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red.opacity(0.15), in: Capsule()).foregroundStyle(.red)
                }
            }
            if let task = request.task, !task.isEmpty {
                Text("For: \(task)").foregroundStyle(.secondary)
            }
            ScrollView {
                Text(request.detail).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(minHeight: 60, maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if !request.hosts.isEmpty {
                let more = request.hosts.count > 12 ? " and \(request.hosts.count - 12) more" : ""
                Text("\(request.hosts.count) machine\(request.hosts.count == 1 ? "" : "s"): \(request.hosts.prefix(12).joined(separator: ", "))\(more)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Deny", role: .cancel) { decide(.deny) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Always Allow") { decide(.always) }
                    .help("\(request.client) runs anything without asking until you revoke it in Settings › MCP Server.")
                Button("Allow for 1 Hour") { decide(.hour) }.help("This connection only.")
                Button("Allow for This Session") { decide(.session) }.help("Until this agent disconnects.")
                Button("Allow Once") { decide(.once) }
            }
            Text("“Always Allow” trusts the name the client gives itself; any program on this Mac could use that name.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(width: 600)
    }
}
