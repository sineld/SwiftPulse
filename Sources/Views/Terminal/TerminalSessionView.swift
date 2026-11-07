import SwiftUI
import SwiftTerm
import SwiftData

struct TerminalSessionView: View {
    let session: TerminalSession
    @Environment(SessionManager.self) private var sessions
    @Environment(DashboardStore.self) private var dashboard
    @Environment(AppState.self) private var state
    @AppStorage("terminalFontSize") private var fontSize = 12.0
    @AppStorage("terminalInspector") private var showInspector = false
    @State private var inspectorTab = 0
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            TerminalHost(view: session.terminalView)
                .frame(minWidth: 300)
                .background(Color(nsColor: session.terminalView.nativeBackgroundColor))
            if showInspector {
                inspector.frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            }
        }
        .navigationTitle(session.title)
        .navigationSubtitle(session.stateText)
        .toolbar {
            ToolbarItem { Button("Open in New Window", systemImage: "macwindow.on.rectangle") { openWindow(value: session.id); state.selection = .machines } }
            ToolbarItem {
                Button("Open in SFTP", systemImage: "folder") {
                    state.selection = .sftpSession(sessions.openSFTP(session.machine, path: session.currentDirectory).id)
                }
                .help(session.currentDirectory.map { "Browse \($0) over SFTP" } ?? "Browse files over SFTP (turn on Shell Integration in Settings to open the terminal's folder)")
            }
            ToolbarItem {
                Menu {
                    Text(session.stateText)
                    Button("Force Restart", systemImage: "arrow.clockwise") { session.restart() }
                    Divider()
                    Menu("Text Size") {
                        Button("Increase", systemImage: "plus") { fontSize = min(fontSize + 1, 32); TerminalTheme.apply(to: session.terminalView) }.keyboardShortcut("+", modifiers: .command)
                        Button("Decrease", systemImage: "minus") { fontSize = max(fontSize - 1, 8); TerminalTheme.apply(to: session.terminalView) }.keyboardShortcut("-", modifiers: .command)
                        Button("Reset") { fontSize = 12; TerminalTheme.apply(to: session.terminalView) }
                    }
                    Divider()
                    Button("Close Session", systemImage: "xmark.circle", role: .destructive) {
                        sessions.close(session); state.selection = .machines
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItem { Toggle(isOn: $showInspector) { Image(systemName: "sidebar.right") }.help("Inspector") }
        }
        .onChange(of: fontSize) { TerminalTheme.apply(to: session.terminalView) }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $inspectorTab) { Text("Snippets").tag(0); Text("Status").tag(1) }
                .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            if inspectorTab == 0 {
                SnippetPickerList { snippet in session.send(text: snippet.script.hasSuffix("\n") ? snippet.script : snippet.script + "\n") }
            } else {
                ScrollView { StatusDetailView(monitor: dashboard.monitor(for: session.machine), compact: true) }
            }
        }
        .background(Theme.pageBackground)
    }
}

/// Hosts the SwiftTerm NSView and gives it keyboard focus.
struct TerminalHost: NSViewRepresentable {
    let view: TerminalView
    func makeNSView(context: Context) -> TerminalView {
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

/// Snippet list used by the terminal inspector; tapping runs the snippet in the terminal.
struct SnippetPickerList: View {
    @Query(sort: \Snippet.name) private var snippets: [Snippet]
    @Query(sort: \SnippetPackage.name) private var packages: [SnippetPackage]
    @State private var query = ""
    let onRun: (Snippet) -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextField("Snippets or Packages", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "Packages")
                    if packages.isEmpty { emptyCard("No snippet packages available") }
                    ForEach(packages.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { p in
                        DisclosureGroup {
                            ForEach((p.snippets ?? []).sorted { $0.name < $1.name }) { s in row(s) }
                        } label: { Label(p.name, systemImage: "shippingbox") }
                        .padding(10).card()
                    }
                    SectionTitle(text: "Snippets")
                    if snippets.isEmpty { emptyCard("No snippets available") }
                    ForEach(snippets.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { s in row(s) }
                }
                .padding(10)
            }
        }
    }

    private func row(_ s: Snippet) -> some View {
        Button { onRun(s) } label: {
            ResourceCard(icon: "curlybraces", title: s.name, subtitle: s.script.split(separator: "\n").dropFirst().first.map(String.init)) {
                Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
            }
        }.buttonStyle(.plain)
    }

    private func emptyCard(_ text: String) -> some View {
        VStack(spacing: 8) { Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.tertiary); Text(text).font(.caption) }
            .frame(maxWidth: .infinity).padding(20).card()
    }
}
