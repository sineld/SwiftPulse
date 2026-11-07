import SwiftUI
import SwiftData

struct MachineFormSheet: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Identity.name) private var identities: [Identity]
    @Query(sort: \SSHKey.name) private var keys: [SSHKey]
    @Query(sort: \Proxy.name) private var proxies: [Proxy]
    @Query(sort: \MachineGroup.name) private var groups: [MachineGroup]
    @Query(sort: \Machine.name) private var allMachines: [Machine]
    var machine: Machine?
    var duplicateOf: Machine? = nil

    @State private var name = ""
    @State private var host = ""
    @State private var port = 22
    @State private var useJumpHost = false
    @State private var jumpHosts: [Machine] = []
    @State private var proxy: Proxy?
    @State private var proxyCommand = ""
    @State private var authMethod: AuthMethod = .identity
    @State private var identity: Identity?
    @State private var username = ""
    @State private var password = ""
    @State private var sshKey: SSHKey?
    @State private var connection: ConnectionKind = .ssh
    @State private var group: MachineGroup?
    @State private var tags: [String] = []
    @State private var showInDashboard = true
    @State private var hiddenFromAgents = false
    @State private var sftpPath = "/"
    @State private var remark = Machine.defaultRemark()
    @State private var pick: Pick?
    @State private var create: Create?
    @State private var editTags = false
    @State private var testResult: TestResult?
    enum TestResult { case running, ok(String), failed(String) }

    enum Pick: Identifiable { case jumpHost, proxy, identity, sshKey, group; var id: Self { self } }
    enum Create: Identifiable { case proxy, identity, sshKey, group; var id: Self { self } }

    private var canSave: Bool {
        guard !host.isEmpty, port > 0 else { return false }
        switch authMethod {
        case .identity: return identity != nil
        case .passwordOrKey: return !username.isEmpty && (!password.isEmpty || sshKey != nil)
        case .keyboardInteractive, .noAuthentication: return !username.isEmpty
        }
    }

    var body: some View {
        FormSheet(title: machine == nil ? "Create New Machine" : "Edit Machine", canSave: canSave, onSave: save) {
            Section {
                TextField("Name", text: $name, prompt: Text("Name"))
                TextField("Host", text: $host, prompt: Text("IP or Hostname"))
                TextField("Port", value: $port, format: .number)
            } header: { Label("Machine Information", systemImage: "info.circle") }
              footer: { Text("If Name is empty, Host will be used as Name.") }

            Section {
                Toggle("Use Jump Host", isOn: $useJumpHost)
                if useJumpHost {
                    ForEach(Array(jumpHosts.enumerated()), id: \.offset) { index, hop in
                        HStack {
                            Label(hop.displayName, systemImage: "server.rack")
                            Spacer()
                            Button(role: .destructive) { jumpHosts.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                    Button("Add Hop", systemImage: "plus.circle") { pick = .jumpHost }
                }
            } header: { Label("Jump Host", systemImage: "point.3.connected.trianglepath.dotted") }
              footer: { if useJumpHost { Text("Dashboard status is disabled when any hop needs an interactive prompt.") } }

            Section {
                LabeledContent("Proxy") { ChipButton(title: proxy?.name ?? "Create or Select Proxy", icon: "globe") { pick = .proxy } }
                TextField("ProxyCommand", text: $proxyCommand, prompt: Text("cloudflared access ssh --hostname %h"))
                    .font(.body.monospaced())
            } header: { Label("Connection Proxy", systemImage: "globe") }
              footer: { Text("A ProxyCommand replaces the direct connection, as in ssh_config: %h is the host, %p the port, %r the user. It takes precedence over the proxy.") }

            Section {
                Picker("Method", selection: $authMethod) { ForEach(AuthMethod.allCases) { Text($0.title).tag($0) } }
                switch authMethod {
                case .identity:
                    LabeledContent("Identity") { ChipButton(title: identity?.name ?? "Select Identity", icon: "person") { pick = .identity } }
                case .passwordOrKey:
                    TextField("Username", text: $username, prompt: Text("Username"))
                    SecretField(label: "Password", text: $password)
                    LabeledContent("SSH Key") { ChipButton(title: sshKey?.name ?? "Select SSH Key", icon: "key") { pick = .sshKey } }
                case .keyboardInteractive:
                    TextField("Username", text: $username, prompt: Text("Username"))
                    SecretField(label: "Password", text: $password)
                case .noAuthentication:
                    TextField("Username", text: $username, prompt: Text("Username"))
                    Text("For servers that trust the connection itself, such as Tailscale SSH: no password or key is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Label("Authentication", systemImage: "lock.circle") }

            Section {
                Picker("Connection", selection: $connection) { ForEach(ConnectionKind.allCases) { Text($0.title).tag($0) } }
                HStack {
                    Button("Test Connection", action: testConnection).disabled(!canSave || isTesting).accessibilityLabel("Test Connection")
                    Spacer()
                    switch testResult {
                    case .running: ProgressView().controlSize(.small)
                    case .ok(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
                    case .failed(let text): Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
                    case nil: EmptyView()
                    }
                }
            } header: { Label("Terminal", systemImage: "terminal") }
              footer: { Text("It is recommended to test connection before saving.") }

            Section {
                LabeledContent("Group") { ChipButton(title: group?.name ?? "Select Group", icon: "square.grid.2x2") { pick = .group } }
                LabeledContent("Tags") { ChipButton(title: tags.isEmpty ? "Edit Tags" : tags.joined(separator: ", "), icon: "tag") { editTags = true } }
            } header: { Label("Categorization", systemImage: "tag") }

            Section {
                Toggle("Show Status in Dashboard", isOn: $showInDashboard)
                Toggle("Hide from AI Agents", isOn: $hiddenFromAgents)
                    .help("The MCP server doesn't show this machine to agents, and they can't run anything on it.")
                TextField("Default SFTP Path", text: $sftpPath)
            } header: { Label("Preferences", systemImage: "gearshape") }

            Section { TextField("Machine Remark", text: $remark, axis: .vertical) } header: { Label("Remark", systemImage: "note.text") }
        }
        .onAppear(perform: load)
        .sheet(item: $pick, content: picker)
        .sheet(item: $create, content: creator)
        .sheet(isPresented: $editTags) { TagEditorSheet(tags: $tags) }
    }

    @ViewBuilder private func picker(_ which: Pick) -> some View {
        switch which {
        case .jumpHost:
            PickerSheet(title: "Select Jump Host", items: allMachines.filter { $0.id != machine?.id }, onSelect: { if let m = $0 { jumpHosts.append(m) } },
                        row: { ResourceCard(icon: "server.rack", title: $0.displayName, subtitle: $0.host) },
                        matches: { $0.displayName.localizedCaseInsensitiveContains($1) })
        case .proxy:
            PickerSheet(title: "Select Proxy", items: proxies, noneTitle: "No Proxy", onCreate: { pick = nil; create = .proxy }, onSelect: { proxy = $0 },
                        row: { ResourceCard(icon: "globe", title: $0.name, subtitle: "\($0.kind.title) · \($0.host):\($0.port)") },
                        matches: { $0.name.localizedCaseInsensitiveContains($1) })
        case .identity:
            PickerSheet(title: "Select Identity", items: identities, onCreate: { pick = nil; create = .identity }, onSelect: { identity = $0 },
                        row: { ResourceCard(icon: "person", title: $0.name, subtitle: $0.username) },
                        matches: { $0.name.localizedCaseInsensitiveContains($1) })
        case .sshKey:
            PickerSheet(title: "Select SSH Key", items: keys, noneTitle: "No SSH Key", onCreate: { pick = nil; create = .sshKey }, onSelect: { sshKey = $0 },
                        row: { ResourceCard(icon: "key", title: $0.name, subtitle: $0.keyType.title) },
                        matches: { $0.name.localizedCaseInsensitiveContains($1) })
        case .group:
            PickerSheet(title: "Select Machine Group", items: groups, noneTitle: "No Group", onCreate: { pick = nil; create = .group }, onSelect: { group = $0 },
                        row: { ResourceCard(icon: "square.grid.2x2", title: $0.name, subtitle: "\($0.machines?.count ?? 0) Machines") },
                        matches: { $0.name.localizedCaseInsensitiveContains($1) })
        }
    }

    @ViewBuilder private func creator(_ which: Create) -> some View {
        switch which {
        case .proxy: ProxyFormSheet { proxy = $0 }
        case .identity: IdentityFormSheet { identity = $0 }
        case .sshKey: SSHKeyGenerateSheet { sshKey = $0 }
        case .group: GroupFormSheet { group = $0 }
        }
    }

    private var isTesting: Bool { if case .running = testResult { true } else { false } }

    /// Spec straight from the form values. Never instantiates a `Machine`: a @Model related to a stored
    /// identity would be auto-inserted into the store (that is how "Test Connection" used to create phantom machines).
    private func currentSpec() throws -> ConnectionSpec {
        let fields = ConnectionSpec.Fields(host: host, port: port, authMethod: authMethod, identity: identity, username: username,
                                           sshKey: sshKey, proxy: proxy, jumpHostIDs: useJumpHost ? jumpHosts.map(\.id) : [],
                                           passwordKey: machine?.passwordKey, enteredPassword: password, proxyCommand: proxyCommand)
        return try ConnectionSpec.make(fields, in: context)
    }

    private func testConnection() {
        testResult = .running
        Task {
            do {
                let spec = try currentSpec()
                let banner = try await SSHService.test(spec, container: context.container)
                testResult = .ok(banner.split(separator: "\n").first.map(String.init) ?? "Connected")
            } catch { testResult = .failed(error.localizedDescription) }
        }
    }

    private func load() {
        guard let source = machine ?? duplicateOf else { return }
        name = machine == nil ? source.name + " Copy" : source.name
        host = source.host; port = source.port; useJumpHost = source.useJumpHost
        jumpHosts = source.jumpHostIDs.compactMap { id in allMachines.first { $0.id == id } }
        proxy = source.proxy; proxyCommand = source.proxyCommand; authMethod = source.authMethod; identity = source.identity; username = source.username
        sshKey = source.sshKey; connection = source.connection; group = source.group; tags = source.tags
        showInDashboard = source.showInDashboard; sftpPath = source.defaultSFTPPath; remark = source.remark
        hiddenFromAgents = source.hiddenFromAgents
        password = KeychainService.get(source.passwordKey) ?? ""
    }

    private func save() {
        let target = machine ?? Machine()
        target.name = name; target.host = host; target.port = port
        target.useJumpHost = useJumpHost; target.jumpHostIDs = useJumpHost ? jumpHosts.map(\.id) : []
        target.proxy = proxy; target.proxyCommand = proxyCommand.trimmingCharacters(in: .whitespaces); target.authMethod = authMethod
        target.identity = authMethod == .identity ? identity : nil
        target.username = authMethod == .identity ? "" : username
        target.sshKey = authMethod == .passwordOrKey ? sshKey : nil
        target.connection = connection; target.group = group; target.tags = tags
        target.showInDashboard = showInDashboard; target.defaultSFTPPath = sftpPath; target.remark = remark
        target.hiddenFromAgents = hiddenFromAgents
        KeychainService.set(authMethod == .identity || authMethod == .noAuthentication || password.isEmpty ? nil : password, for: target.passwordKey)
        if machine == nil { context.insert(target) }
    }
}

struct TagEditorSheet: View {
    @Binding var tags: [String]
    @State private var newTag = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Tags").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            Divider()
            List {
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Label(tag, systemImage: "tag")
                        Spacer()
                        Button(role: .destructive) { tags.removeAll { $0 == tag } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("New tag", text: $newTag).onSubmit(add)
                    Button("Add", action: add).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 380, height: 360)
    }

    private func add() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        tags.append(tag); newTag = ""
    }
}
