import SwiftUI
import SwiftData

@main
struct SwiftPulseApp: App {
    private let container: ModelContainer
    @State private var appState = AppState()
    @State private var dashboard: DashboardStore
    @State private var sessions: SessionManager
    @State private var docker: DockerStore
    @State private var sync: SyncService
    @AppStorage("colorScheme") private var colorScheme = "system"
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = true

    init() {
        // As the unit tests' host the app keeps off the user's data: an in-memory store, no MCP socket, no sync.
        let testing = KeychainService.isRunningTests
        let container = AppSchema.container(inMemory: testing)
        self.container = container
        let dashboard = DashboardStore(container: container)
        _dashboard = State(initialValue: dashboard)
        let sessions = SessionManager(container: container)
        _sessions = State(initialValue: sessions)
        let docker = DockerStore()
        _docker = State(initialValue: docker)
        _sync = State(initialValue: SyncService(container: container))
        SyncTombstones.observe()
        AgentSocket.shared.server = MCPServer(container: container, dashboard: dashboard, sessions: sessions, docker: docker)
        AgentSocket.shared.apply(enabled: !testing && UserDefaults.standard.bool(forKey: AgentSettingsView.enabledKey))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView()
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(colorScheme == "light" ? .light : colorScheme == "dark" ? .dark : nil)
                .environment(appState)
                .environment(dashboard)
                .environment(sessions)
                .environment(docker)
                .environment(sync)
                .task { if !KeychainService.isRunningTests { sync.start() } }
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 780)
        .commands { AppCommands() }

        WindowGroup("Terminal", for: UUID.self) { $id in
            if let id, let session = sessions.terminal(id) {
                TerminalSessionView(session: session)
                    .environment(appState).environment(dashboard).environment(sessions)
                    .frame(minWidth: 600, minHeight: 400)
            } else { ContentUnavailableView("Session closed", systemImage: "terminal") }
        }
        .modelContainer(container)
        .defaultSize(width: 900, height: 600)

        WindowGroup("Editor", for: EditorTarget.self) { $target in
            if let target { RemoteFileEditorView(target: target).environment(sessions) }
        }
        .defaultSize(width: 700, height: 470)

        MenuBarExtra(isInserted: $showMenuBarMonitor) {
            MenuBarMonitorView().environment(dashboard).modelContainer(container)
        } label: {
            Image(systemName: "waveform.path.ecg")
            if dashboard.offlineCount > 0 { Text("\(dashboard.offlineCount)") } // machines down, at a glance
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .modelContainer(container)
                .environment(sync)
        }
    }
}
