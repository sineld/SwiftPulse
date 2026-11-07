import SwiftUI
import SwiftData

/// Settings window: grouped sections with drill-down subpages.
struct SettingsView: View {
    @AppStorage("connectionTimeout") private var connectionTimeout = 15
    @AppStorage("alwaysTrustHostKeys") private var alwaysTrustHostKeys = false
    @AppStorage("requireAuthentication") private var requireAuthentication = false
    @AppStorage("terminalBell") private var terminalBell = true
    @AppStorage(TerminalSession.shellIntegrationKey) private var shellIntegration = false
    @AppStorage("suggestPortForwarding") private var suggestPortForwarding = false
    @AppStorage("keepAlive") private var keepAlive = true
    @AppStorage("keepAliveInterval") private var keepAliveInterval = 10
    @AppStorage("sftpKeepAlive") private var sftpKeepAlive = true
    @AppStorage("snippetTimeout") private var snippetTimeout = 15
    @AppStorage("dockerRefreshInterval") private var dockerRefreshInterval = 5


    @Environment(SyncService.self) private var sync

    private var syncStatus: String {
        guard sync.isConfigured else { return "Not set up" }
        guard let date = sync.lastExport else { return "Folder ready" }
        return "Exported \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 6) {
                        Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                        Text("SwiftPulse").font(.headline)
                        Text("Server monitoring, SSH terminal, SFTP and tunnels.").font(.caption).foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0") · Sinan Eldem").font(.caption2).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                Section("Appearance") {
                    NavigationLink { DashboardSettingsView() } label: { Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent") }
                    NavigationLink { TerminalThemeSettingsView() } label: { Label("Terminal Theme", systemImage: "terminal") }
                    NavigationLink { AppAppearanceSettingsView() } label: { Label("App Appearance", systemImage: "paintpalette") }
                }
                Section {
                    NavigationLink { SyncSettingsView() } label: {
                        Label("Local Sync", systemImage: "folder.badge.gearshape")
                    }
                    LabeledContent("Status") { Text(syncStatus).foregroundStyle(.secondary) }
                } header: { Text("Data Sync") } footer: {
                    Text("Settings and machines are exported to an encrypted file in a folder you choose, so your own cloud client (Nextcloud, Dropbox, Syncthing) carries them to your other Macs. No account and no iCloud involved.")
                }
                Section {
                    Toggle(isOn: $requireAuthentication) { Label("Require Authentication", systemImage: "lock.shield") }
                } footer: { Text("When enabled, viewing saved passwords, SSH private keys and passphrases requires Touch ID or your login password.") }
                Section("Connection") {
                    Stepper("Connection Timeout: \(connectionTimeout) seconds", value: $connectionTimeout, in: 5...120, step: 5)
                    Toggle(isOn: $alwaysTrustHostKeys) { Label("Trust New Host Keys Automatically", systemImage: "key.viewfinder") }
                        .help("Hosts seen for the first time are trusted without asking. A key that differs from the saved one always asks.")
                    NavigationLink("Known Hosts") { KnownHostsSettingsView() }
                }
                Section {
                    NavigationLink { AgentSettingsView() } label: { Label("MCP Server", systemImage: "sparkles") }
                } header: { Text("AI Agents") } footer: {
                    Text("Lets Claude Code, Codex and other MCP clients see your machines and, once you approve each run, execute commands with SwiftPulse's saved credentials.")
                }
                Section {
                    Toggle("Terminal Bell", isOn: $terminalBell)
                    Toggle("Shell Integration", isOn: $shellIntegration)
                        .help("Types a one-line hook into bash or zsh when a terminal opens, so SwiftPulse knows the shell's folder and Open in SFTP starts there.")
                    Toggle("Suggest Port Forwarding", isOn: $suggestPortForwarding)
                    Toggle("Keep Session Alive", isOn: $keepAlive)
                    Stepper("Alive Interval: \(keepAliveInterval) seconds", value: $keepAliveInterval, in: 5...120, step: 5)
                } header: { Text("Terminal") } footer: {
                    Text("When Suggest Port Forwarding is on, SwiftPulse offers to forward a port when terminal output mentions a local address such as localhost:3000.")
                }
                Section("SFTP") {
                    Toggle("Keep Session Alive", isOn: $sftpKeepAlive)
                }
                Section("Docker") {
                    Picker("Refresh Interval", selection: $dockerRefreshInterval) {
                        ForEach([3, 5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    Text("How often the Docker panel re-reads containers, stats and disk usage while it is open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Snippet") {
                    Stepper("Snippet Execution Timeout: \(snippetTimeout) seconds", value: $snippetTimeout, in: 5...300, step: 5)
                    NavigationLink("Machine Tags") { MachineTagsSettingsView() }
                }
                Section("Support") {
                    Link(destination: URL(string: "https://github.com/sineld/SwiftPulse/issues")!) { Label("Feedback", systemImage: "envelope") }
                    NavigationLink { LogsSettingsView() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                }
                Section("About") {
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))")
                    LabeledContent("Author", value: "Sinan Eldem")
                    LabeledContent("Email") { Link("sinan@sinaneldem.tr", destination: URL(string: "mailto:sinan@sinaneldem.tr")!) }
                    LabeledContent("Website") { Link("sinaneldem.tr", destination: URL(string: "https://sinaneldem.tr")!) }
                    NavigationLink("Open Source License") { LicensesView() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
        .frame(width: 600, height: 760)
    }
}

struct DashboardSettingsView: View {
    @AppStorage("dashboardRefreshInterval") private var refresh = 5
    @AppStorage("showTagFilters") private var showTagFilters = true
    @AppStorage("showServerListTags") private var showServerListTags = true
    @AppStorage("showLatency") private var showLatency = true
    @AppStorage("colorizeLatency") private var colorizeLatency = true
    @AppStorage("reduceAnimations") private var reduceAnimations = false
    @AppStorage("temperatureUnit") private var temperatureUnit = "celsius"
    @AppStorage("networkAsBits") private var networkAsBits = false
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = true

    var body: some View {
        Form {
            Section {
                Toggle("Show Monitor in Menu Bar", isOn: $showMenuBarMonitor)
            } header: { Text("Menu Bar") } footer: {
                Text("Every dashboard machine with its state, CPU and memory, from the menu bar. The icon shows how many are offline.")
            }
            Section("Status Refresh") {
                Picker("Refresh Interval", selection: $refresh) { ForEach([2, 3, 5, 10, 15, 30, 60], id: \.self) { Text("\($0) seconds").tag($0) } }
                Text("Machine status polling uses a fixed delay: SwiftPulse waits this long after the previous sample returns before sending the next request.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Tags") {
                Toggle("Show Tag Filters", isOn: $showTagFilters)
                Toggle("Show Server List Tags", isOn: $showServerListTags)
            }
            Section("Latency Display") {
                Toggle("Show Latency", isOn: $showLatency)
                Toggle("Colorize Latency", isOn: $colorizeLatency)
            }
            Section("Motion") { Toggle("Reduce Live Status Animations", isOn: $reduceAnimations) }
            Section("Display Units") {
                Picker("Temperature", selection: $temperatureUnit) { Text("Celsius").tag("celsius"); Text("Fahrenheit").tag("fahrenheit") }
                Toggle("Show Network as Bits", isOn: $networkAsBits)
            }
        }
        .formStyle(.grouped).navigationTitle("Dashboard")
    }
}

struct TerminalThemeSettingsView: View {
    @AppStorage("terminalTheme") private var theme = ""
    @AppStorage("terminalFontName") private var fontName = "Menlo"
    @AppStorage("terminalFontSize") private var fontSize = 12.0
    @AppStorage("terminalCursor") private var cursor = "block"
    @AppStorage("terminalCursorBlink") private var blink = false
    private let fonts = ["Menlo", "SF Mono", "Monaco", "Courier New", "JetBrains Mono", "Fira Code", "Source Code Pro"]

    var body: some View {
        Form {
            Section("Preview") {
                let t = TerminalTheme.all.first { $0.name == theme } ?? TerminalTheme.current
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to SwiftPulse!").bold()
                    HStack(spacing: 6) { ForEach(0..<8, id: \.self) { i in Text("Hi").foregroundStyle(Color(nsColor: t.ansi[i])) } }
                    HStack(spacing: 6) { ForEach(8..<16, id: \.self) { i in Text("Hi").foregroundStyle(Color(nsColor: t.ansi[i])) } }
                    Text("Customize your terminal theme color, font size and font family.")
                }
                .font(.custom(fontName, size: fontSize)).foregroundStyle(Color(nsColor: t.foreground))
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: t.background), in: RoundedRectangle(cornerRadius: 8))
            }
            Section("Font") {
                Stepper("Size: \(Int(fontSize))", value: $fontSize, in: 8...32)
                Picker("Font", selection: $fontName) { ForEach(fonts, id: \.self) { Text($0).tag($0) } }
                Text("To use custom fonts, install the font files in macOS, then select them from this list.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Color Palette") {
                Picker("Theme", selection: $theme) {
                    Text("Follow System").tag("")
                    ForEach(TerminalTheme.all) { Text($0.name).tag($0.name) }
                }
                Text("Terminal themes will be applied to new terminals.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Cursor") {
                Picker("Active Cursor", selection: $cursor) { Text("Block").tag("block"); Text("Underline").tag("underline"); Text("Bar").tag("bar") }
                Toggle("Cursor Blink", isOn: $blink)
            }
        }
        .formStyle(.grouped).navigationTitle("Terminal Theme")
    }
}

struct AppAppearanceSettingsView: View {
    @AppStorage("colorScheme") private var scheme = "system"
    var body: some View {
        Form {
            Section("Language") {
                LabeledContent("Current App Language", value: Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier)
                Button("Open Language & Region") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!) }
            }
            Section("Color Scheme") {
                Picker("Color Scheme", selection: $scheme) { Text("System").tag("system"); Text("Light Mode").tag("light"); Text("Dark Mode").tag("dark") }
                    .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped).navigationTitle("App Appearance")
    }
}

struct KnownHostsSettingsView: View {
    @Query(sort: \KnownHostKey.host) private var keys: [KnownHostKey]
    @Environment(\.modelContext) private var context
    @State private var pendingDelete: DeleteRequest?
    var body: some View {
        Form {
            if keys.isEmpty { Text("No host keys saved yet.").foregroundStyle(.secondary) }
            ForEach(keys) { key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(key.host):\(key.port)").font(.body.weight(.medium))
                    Text("\(key.keyType) · added \(key.addedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Forget", systemImage: "trash", role: .destructive) {
                        pendingDelete = .ask(title: "Forget Host Key",
                                             message: "Forget the \(key.keyType) key of \(key.host):\(key.port)? SwiftPulse will ask you to trust it again on the next connection.",
                                             confirmTitle: "Forget") { context.delete(key) }
                    }
                }
            }
        }
        .formStyle(.grouped).navigationTitle("Known Hosts")
        .deleteConfirmation($pendingDelete)
    }
}

struct MachineTagsSettingsView: View {
    @Query private var machines: [Machine]
    var body: some View {
        let counts = Dictionary(grouping: machines.flatMap(\.tags), by: { $0 }).mapValues(\.count)
        Form {
            if counts.isEmpty { Text("No tags yet. Add tags when editing a machine.").foregroundStyle(.secondary) }
            ForEach(counts.keys.sorted(), id: \.self) { tag in
                LabeledContent(tag, value: "\(counts[tag] ?? 0) machine\(counts[tag] == 1 ? "" : "s")")
            }
        }
        .formStyle(.grouped).navigationTitle("Machine Tags")
    }
}

struct LogsSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SessionRecord.createdAt, order: .reverse) private var sessions: [SessionRecord]
    var body: some View {
        Form {
            Section("Data Store") {
                LabeledContent("Session Records", value: "\(sessions.count)")
                LabeledContent("Store", value: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
            Section("Recent") {
                ForEach(AppLog.shared.entries.suffix(50).reversed()) { entry in
                    HStack(alignment: .top) {
                        Text(entry.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        Text(entry.message).font(.caption)
                    }
                }
                if AppLog.shared.entries.isEmpty { Text("Nothing logged yet.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped).navigationTitle("Logs")
    }
}

struct LicensesView: View {
    private let items: [(String, String, String)] = [
        ("Citadel", "SSH2 client and SFTP implementation on top of SwiftNIO SSH.", "https://github.com/orlandos-nl/Citadel"),
        ("SwiftTerm", "VT100/xterm terminal emulator for macOS.", "https://github.com/migueldeicaza/SwiftTerm"),
        ("SwiftNIO SSH", "SSH protocol implementation by Apple.", "https://github.com/apple/swift-nio-ssh"),
        ("Swift Crypto", "Cryptographic primitives.", "https://github.com/apple/swift-crypto"),
        ("BigInt", "Arbitrary-precision arithmetic.", "https://github.com/attaswift/BigInt"),
    ]
    var body: some View {
        Form {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0).font(.body.weight(.medium))
                    Text(item.1).font(.caption).foregroundStyle(.secondary)
                    Link("Learn More", destination: URL(string: item.2)!).font(.caption)
                }
            }
        }
        .formStyle(.grouped).navigationTitle("Open Source License")
    }
}
