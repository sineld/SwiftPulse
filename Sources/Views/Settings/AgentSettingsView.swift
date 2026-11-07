import SwiftUI
import SwiftData
import AppKit

/// Settings > MCP Server: turns the agent socket on or off, shows how to connect an MCP client, which clients are
/// connected or always allowed, and what agents did.
struct AgentSettingsView: View {
    static let enabledKey = "mcpEnabled"
    @AppStorage(AgentSettingsView.enabledKey) private var enabled = false
    @State private var running = AgentSocket.shared.isRunning
    @State private var alwaysAllowed = AgentApproval.alwaysAllowed
    @State private var skillMessage: String?
    @AppStorage(AgentApproval.autoApproveKey) private var autoApproveReadOnly = false
    @AppStorage(AgentApproval.readOnlyCommandsKey) private var readOnlyCommands = AgentApproval.defaultReadOnlyCommands

    /// The stdio command MCP clients launch; it relays to the app's socket.
    static var helperPath: String {
        Bundle.main.url(forResource: "swiftpulse-mcp", withExtension: nil)?.path
            ?? "/Applications/SwiftPulse.app/Contents/Resources/swiftpulse-mcp"
    }

    static var bundledSkill: URL? { Bundle.main.url(forResource: "skills", withExtension: nil)?.appendingPathComponent("swiftpulse") }
    static var installedSkill: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/swiftpulse") }

    private var claudeCommand: String { "claude mcp add swiftpulse -- \"\(Self.helperPath)\"" }
    private var codexConfig: String { "[mcp_servers.swiftpulse]\ncommand = \"\(Self.helperPath)\"" }
    private var agentPrompt: String {
        "My SSH machines are in SwiftPulse, which runs an MCP server. Connect to it as a stdio MCP server with the command "
            + "\"\(Self.helperPath)\". Read its instructions at \"\(Self.bundledSkill?.appendingPathComponent("SKILL.md").path ?? "SKILL.md")\" "
            + "before working on my machines."
    }

    var body: some View {
        Form {
            Section {
                Toggle("MCP Server", isOn: $enabled)
                LabeledContent("Status") {
                    Text(running ? "Listening" : "Off").foregroundStyle(running ? .green : .secondary)
                }
            } footer: {
                Text("Agents can list machines and read live metrics and Docker state. Everything they want to change or run asks you first, and passwords and private keys are never sent to them. The server listens on a socket only your user account can open; there is no network port.")
            }
            if running { ConnectedClients() }
            if !alwaysAllowed.isEmpty {
                Section {
                    ForEach(alwaysAllowed, id: \.self) { client in
                        LabeledContent(client) {
                            Button("Revoke", role: .destructive) {
                                AgentApproval.revokeAlways(client)
                                alwaysAllowed = AgentApproval.alwaysAllowed
                            }
                        }
                    }
                } header: { Text("Always Allowed") } footer: {
                    Text("These clients run commands and make changes without asking. The name is the one the client gives itself.")
                }
            }
            Section {
                Toggle("Run Read-Only Commands Without Asking", isOn: $autoApproveReadOnly)
                if autoApproveReadOnly {
                    TextEditor(text: $readOnlyCommands).font(.system(.caption, design: .monospaced)).frame(minHeight: 110)
                    Button("Restore Defaults") { readOnlyCommands = AgentApproval.defaultReadOnlyCommands }
                }
            } header: { Text("Approval") } footer: {
                Text("One command per line; it also matches with arguments (\"df\" covers \"df -h\"). Only without sudo, and never when the command contains ; & | $ ` < > quotes, globs or brackets. These runs still show in Activity.")
            }
            Section("Claude Code") {
                command(claudeCommand)
                HStack {
                    Button("Install Skill") { installSkill() }.disabled(Self.bundledSkill == nil)
                    if let skillMessage { Text(skillMessage).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Codex (~/.codex/config.toml)") { command(codexConfig) }
            Section("Any Other Agent") { command(agentPrompt) }
            Section {
                NavigationLink { AgentActivityView() } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }
            } footer: {
                Text("Every run and change agents asked for, approved or not, and what they reported doing on their own, machine by machine.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("MCP Server")
        .onChange(of: enabled) { _, on in
            AgentSocket.shared.apply(enabled: on)
            running = AgentSocket.shared.isRunning
        }
        .onAppear { alwaysAllowed = AgentApproval.alwaysAllowed }
    }

    private func command(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    /// Copies the bundled skill to ~/.claude/skills/swiftpulse, replacing an older copy.
    private func installSkill() {
        guard let source = Self.bundledSkill else { return }
        let target = Self.installedSkill
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            skillMessage = "Installed in ~/.claude/skills/swiftpulse"
        } catch {
            skillMessage = error.localizedDescription
        }
    }
}

/// The clients connected right now.
private struct ConnectedClients: View {
    var body: some View {
        Section("Connected") {
            let clients = AgentSocket.shared.server?.clients ?? []
            if clients.isEmpty {
                Text("No agent is connected.").foregroundStyle(.secondary)
            }
            ForEach(clients) { client in
                LabeledContent(client.name) {
                    Text(client.lastSeen, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// What agents did, newest first, for every machine or one.
struct AgentActivityView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AgentActivity.updated, order: .reverse) private var entries: [AgentActivity]
    @Query(sort: \Machine.name) private var machines: [Machine]
    @State private var machineID: String
    @State private var pendingDelete: DeleteRequest?

    /// Every machine's activity, or one machine's to start with.
    init(machineID: String = "") { _machineID = State(initialValue: machineID) }

    private var shown: [AgentActivity] {
        machineID.isEmpty ? entries : entries.filter { $0.hostIDs.contains(machineID) }
    }

    var body: some View {
        Form {
            Picker("Machine", selection: $machineID) {
                Text("All Machines").tag("")
                ForEach(machines) { Text($0.displayName).tag($0.id.uuidString) }
            }
            if shown.isEmpty {
                Text("No agent activity yet.").foregroundStyle(.secondary)
            }
            ForEach(shown) { entry in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        if entry.task != nil {
                            ForEach(Array(entry.steps.enumerated()), id: \.offset) { _, step in
                                stepView(date: step.date, summary: step.summary, detail: step.detail, outcome: step.outcome, results: step.results)
                            }
                        } else {
                            stepView(date: entry.date, summary: entry.summary, detail: entry.detail, outcome: entry.outcome, results: entry.results)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary).font(.body.weight(.medium))
                        Text("\(entry.client) · \(entry.hostNames.joined(separator: ", ")) · \(entry.outcome)")
                            .font(.caption).foregroundStyle(entry.outcome == "declined" ? .orange : .secondary)
                        Text(entry.updated.formatted(date: .abbreviated, time: .shortened) + " · " + entry.device)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agent Activity")
        .toolbar {
            Button("Clear", systemImage: "trash") {
                pendingDelete = .confirm(kind: "Agent Activity", name: "all entries", note: "Other Macs keep theirs.") {
                    entries.forEach(context.delete)
                    SyncVault.defaults.set(Date(), forKey: SyncVault.activityClearedKey) // and sync won't bring them back
                }
            }
            .disabled(entries.isEmpty)
        }
        .deleteConfirmation($pendingDelete)
    }

    private func stepView(date: Date, summary: String, detail: String, outcome: String, results: [AgentActivity.Result]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(date.formatted(date: .omitted, time: .shortened)) · \(summary) · \(outcome)").font(.caption.weight(.medium))
            if !detail.isEmpty {
                Text(detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                Text("\(result.host): \(result.exitCode.map { "exit \($0)" } ?? "failed")" + (result.tail.isEmpty ? "" : "\n\(result.tail.suffix(400))"))
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled).foregroundStyle(.tertiary)
            }
        }
    }
}
