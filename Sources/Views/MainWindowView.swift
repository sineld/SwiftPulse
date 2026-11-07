import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) private var state
    @Environment(SessionManager.self) private var sessions

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView(selection: $state.selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            ContentRouter(item: state.selection ?? .machines)
        }
        .onAppear { sessions.autoStartForwarding() }
    }
}

struct ContentRouter: View {
    let item: SidebarItem
    @Environment(SessionManager.self) private var sessions

    var body: some View {
        Group {
            switch item {
            case .dashboard: DashboardView()
            case .machines: MachinesView()
            case .identities: IdentitiesView()
            case .sshKeys: SSHKeysView()
            case .proxies: ProxiesView()
            case .snippets: SnippetsView()
            case .docker: DockerView()
            case .portForwarding: PortForwardingView()
            case .terminalSession(let id):
                if let session = sessions.terminal(id) { TerminalSessionView(session: session) }
                else { ContentUnavailableView("Session closed", systemImage: "terminal") }
            case .sftpSession(let id):
                if let session = sessions.sftp(id) { SFTPSessionView(session: session) }
                else { ContentUnavailableView("Session closed", systemImage: "folder") }
            case .forwardingSession(let id):
                if let session = sessions.forwarding(id) { ForwardingSessionView(session: session) }
                else { ContentUnavailableView("Session closed", systemImage: "arrow.left.arrow.right") }
            case .history(let id): SessionHistoryView(recordID: id)
            }
        }
        .background(Theme.pageBackground)
    }
}
