import SwiftUI
import SwiftData

struct SessionHistoryView: View {
    let recordID: UUID
    @Query private var records: [SessionRecord]
    @Query private var machines: [Machine]
    @Environment(\.modelContext) private var context
    @Environment(SessionManager.self) private var sessions
    @Environment(AppState.self) private var state
    @State private var pendingDelete: DeleteRequest?

    init(recordID: UUID) {
        self.recordID = recordID
        _records = Query(filter: #Predicate<SessionRecord> { $0.id == recordID })
    }

    var body: some View {
        if let record = records.first {
            Page(title: record.machineName) {
                Form {
                    Section {
                        DetailRow(label: "Machine", value: record.machineName)
                        DetailRow(label: "Session Type", value: record.kind.title)
                    }
                    Section {
                        DetailRow(label: "Host", value: record.host)
                        DetailRow(label: "Port", value: "\(record.port)")
                        DetailRow(label: "Authentication Method", value: record.authMethod.title)
                        DetailRow(label: "Username", value: record.username)
                    }
                    Section {
                        DetailRow(label: "Created", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        DetailRow(label: "Last Active", value: record.lastActiveAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Section {
                        Button("Reconnect") { reconnect(record) }.disabled(machines.first { $0.id == record.machineID } == nil)
                        Button("Remove", role: .destructive) {
                            pendingDelete = .ask(title: "Remove Session Record",
                                                 message: "Remove the \(record.kind.title) record for “\(record.machineName)” from the history?",
                                                 confirmTitle: "Remove") {
                                context.delete(record)
                                state.selection = .machines
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 420)
            }
            .deleteConfirmation($pendingDelete)
        } else {
            ContentUnavailableView("Session not found", systemImage: "clock.arrow.circlepath")
        }
    }

    private func reconnect(_ record: SessionRecord) {
        guard let machine = machines.first(where: { $0.id == record.machineID }) else { return }
        switch record.kind {
        case .terminal: state.selection = .terminalSession(sessions.openTerminal(machine).id)
        case .sftp: state.selection = .sftpSession(sessions.openSFTP(machine).id)
        case .portForwarding: state.selection = .portForwarding
        }
    }
}
