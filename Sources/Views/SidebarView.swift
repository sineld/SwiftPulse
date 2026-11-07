import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Query(sort: \SessionRecord.lastActiveAt, order: .reverse) private var history: [SessionRecord]
    @Environment(\.modelContext) private var context
    @Environment(SessionManager.self) private var sessions
    @Environment(AppState.self) private var state
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        List(selection: $selection) {
            row(.dashboard)

            Section("Resources") {
                row(.machines, title: "Machine")
                row(.identities, title: "Identity")
                row(.sshKeys)
                row(.proxies)
            }
            Section("Toolbox") {
                row(.snippets, title: "Snippet")
                row(.docker)
                row(.portForwarding)
            }
            Section("Terminal") {
                if sessions.terminals.isEmpty { noSessions } else {
                    ForEach(sessions.terminals) { session in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.title).lineLimit(1)
                                Text(session.stateText).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "terminal") }
                        .tag(SidebarItem.terminalSession(session.id))
                        .contextMenu {
                            Button("Force Restart", systemImage: "arrow.clockwise") { session.restart() }
                            Button("Close Session", systemImage: "xmark.circle", role: .destructive) {
                                sessions.close(session)
                                if state.selection == .terminalSession(session.id) { state.selection = .machines }
                            }
                        }
                    }
                }
            }
            Section("SFTP") {
                if sessions.sftps.isEmpty { noSessions } else {
                    ForEach(sessions.sftps) { session in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.machine.displayName).lineLimit(1)
                                Text(session.stateText).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "folder") }
                        .tag(SidebarItem.sftpSession(session.id))
                        .contextMenu {
                            Button("Close Session", systemImage: "xmark.circle", role: .destructive) {
                                sessions.close(session)
                                if state.selection == .sftpSession(session.id) { state.selection = .machines }
                            }
                        }
                    }
                }
            }
            Section("Port Forwarding") {
                if sessions.forwards.isEmpty { noSessions } else {
                    ForEach(sessions.forwards) { session in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.rule.name).lineLimit(1)
                                Text(session.stateText).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "arrow.left.arrow.right") }
                        .tag(SidebarItem.forwardingSession(session.id))
                        .contextMenu {
                            Button("Stop", systemImage: "stop.circle") { session.stop() }
                            Button("Close Session", systemImage: "xmark.circle", role: .destructive) {
                                sessions.close(session)
                                if state.selection == .forwardingSession(session.id) { state.selection = .portForwarding }
                            }
                        }
                    }
                }
            }
            Section("Session History") {
                if history.isEmpty {
                    noSessions
                } else {
                    ForEach(history) { record in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.machineName).lineLimit(1)
                                Text(record.kind.title).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: record.kind == .sftp ? "folder" : "terminal") }
                        .tag(SidebarItem.history(record.id))
                    }
                    Button("Clear All History", systemImage: "trash") {
                        pendingDelete = .ask(title: "Clear Session History",
                                             message: "Remove all \(history.count) session records?",
                                             confirmTitle: "Clear") {
                            history.forEach(context.delete)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .listStyle(.sidebar)
        .deleteConfirmation($pendingDelete)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SettingsLink { Image(systemName: "gearshape") }
            }
        }
    }

    private func row(_ item: SidebarItem, title: String? = nil) -> some View {
        Label(title ?? item.title, systemImage: item.icon).tag(item)
    }

    private var noSessions: some View {
        Label("No Sessions", systemImage: "rectangle.dashed")
            .foregroundStyle(.secondary)
            .selectionDisabled()
    }
}
