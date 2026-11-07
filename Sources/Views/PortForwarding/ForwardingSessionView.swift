import SwiftUI

struct ForwardingSessionView: View {
    let session: ForwardingSession
    @Environment(SessionManager.self) private var sessions
    @Environment(AppState.self) private var state

    var body: some View {
        Page(title: session.rule.name) {
            Form {
                Section {
                    DetailRow(label: "Machine", value: session.machine.displayName)
                    DetailRow(label: "Mode", value: session.rule.mode.title)
                    DetailRow(label: "Route", value: session.routeText)
                    DetailRow(label: "Status", value: session.stateText)
                }
                Section("Traffic") {
                    DetailRow(label: "Connections", value: "\(session.connections)")
                    DetailRow(label: "Transferred", value: Format.bytes(session.bytes))
                }
                Section {
                    if case .stopped = session.state {
                        Button("Start Again") { Task { await session.start() } }
                    } else {
                        Button("Stop", role: .destructive) { session.stop() }
                    }
                    Button("Close Session") { sessions.close(session); state.selection = .portForwarding }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).frame(minHeight: 380)
        }
        .navigationSubtitle(session.stateText)
    }
}
