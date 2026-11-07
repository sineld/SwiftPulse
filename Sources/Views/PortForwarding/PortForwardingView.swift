import SwiftUI
import SwiftData

struct PortForwardingView: View {
    @Query private var rules: [PortForwardingRule]
    @Query private var machines: [Machine]
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var context
    @Environment(SessionManager.self) private var sessions
    @State private var sheet: Sheet?
    @State private var pendingDelete: DeleteRequest?
    enum Sheet: Identifiable { case new, edit(PortForwardingRule); var id: String { if case .edit(let r) = self { "e\(r.id)" } else { "new" } } }

    var body: some View {
        Page(title: "Port Forwarding") {
            if rules.isEmpty {
                EmptyStateView(message: "No port forwarding rules available, create one now!", buttonTitle: "Create New Port Forwarding") { sheet = .new }
            } else {
                CardGrid(items: rules.filtered(by: state)) { rule in
                    ResourceCard(icon: "arrow.left.arrow.right", title: rule.name, subtitle: subtitle(rule),
                                 badges: [rule.mode.title] + (rule.autoStart ? ["Auto Start"] : [])) {
                        if let running = sessions.forwarding(for: rule) {
                            Button("Open", systemImage: "arrow.right.circle") { state.selection = .forwardingSession(running.id) }
                            Button("Stop", systemImage: "stop.fill", role: .destructive) { sessions.close(running) }
                        } else {
                            Button("Start", systemImage: "play.fill") {
                                if let s = sessions.startForwarding(rule) { state.selection = .forwardingSession(s.id) }
                            }
                        }
                    }
                    .onTapGesture { sheet = .edit(rule) }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { sheet = .edit(rule) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            let running = sessions.forwarding(for: rule)
                            pendingDelete = .confirm(kind: "Port Forwarding", name: rule.name,
                                                     note: running != nil ? "The running tunnel will be stopped." : nil) {
                                if let running { sessions.close(running) }
                                context.delete(rule)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: Bindable(state).searchText)
        .findShortcut()
        .deleteConfirmation($pendingDelete)
        .toolbar { ResourceToolbar { sheet = .new } }
        .sheet(item: $sheet) { which in
            switch which {
            case .new: PortForwardingFormSheet()
            case .edit(let r): PortForwardingFormSheet(rule: r)
            }
        }
    }

    private func subtitle(_ rule: PortForwardingRule) -> String {
        let machine = machines.first { $0.id == rule.machineID }?.displayName ?? "No machine"
        let route = rule.mode == .dynamic ? "SOCKS \(rule.localHost):\(rule.localPort)" : "\(rule.localHost):\(rule.localPort) → \(rule.targetHost):\(rule.targetPort)"
        return "\(machine) · \(route)"
    }
}
