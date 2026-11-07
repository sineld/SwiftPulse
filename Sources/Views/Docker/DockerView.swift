import SwiftUI
import SwiftData

/// Routes inside the Docker section. Values carry ids only, so they stay Hashable across refreshes.
enum DockerRoute: Hashable {
    case machine(UUID)
    case container(UUID, String)
    case image(UUID, String)
    case volume(UUID, String)
    case network(UUID, String)
    case compose(UUID, String)

    var machineID: UUID {
        switch self {
        case .machine(let id), .container(let id, _), .image(let id, _),
             .volume(let id, _), .network(let id, _), .compose(let id, _):
            id
        }
    }
}

struct DockerView: View {
    @Query(sort: \Machine.name) private var machines: [Machine]
    @Environment(AppState.self) private var state
    @Environment(DockerStore.self) private var docker
    @Environment(DashboardStore.self) private var dashboard

    var body: some View {
        NavigationStack {
            Page(title: "Docker") {
                if machines.isEmpty {
                    ContentUnavailableView("No machines", systemImage: "shippingbox",
                                           description: Text("Add a machine to manage its Docker engine."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .card()
                } else {
                    CardGrid(items: machines.filtered(by: state)) { machine in
                        NavigationLink(value: DockerRoute.machine(machine.id)) {
                            DockerMachineCard(machine: machine, session: docker.sessions[machine.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationDestination(for: DockerRoute.self) { route in
                DockerRouter(route: route)
            }
            .searchable(text: Bindable(state).searchText)
            .findShortcut()
        }
    }
}

/// Resolves a route to its machine and session.
struct DockerRouter: View {
    let route: DockerRoute
    @Query private var machines: [Machine]
    @Environment(DockerStore.self) private var docker
    @Environment(DashboardStore.self) private var dashboard

    var body: some View {
        if let machine = machines.first(where: { $0.id == route.machineID }) {
            let session = docker.session(for: machine, dashboard: dashboard)
            switch route {
            case .machine: DockerMachineView(session: session)
            case .container(_, let id): DockerContainerDetailView(session: session, containerID: id)
            case .image(_, let id): DockerImageDetailView(session: session, imageID: id)
            case .volume(_, let name): DockerVolumeDetailView(session: session, volumeName: name)
            case .network(_, let id): DockerNetworkDetailView(session: session, networkID: id)
            case .compose(_, let name): DockerComposeDetailView(session: session, projectName: name)
            }
        } else {
            ContentUnavailableView("Machine not found", systemImage: "shippingbox")
        }
    }
}

struct DockerMachineCard: View {
    let machine: Machine
    let session: DockerSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(machine.displayName).font(.body.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(machine.host).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                status
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var status: some View {
        if let session {
            if session.isReady {
                let inventory = session.inventory
                Text("Docker \(inventory.engine.version) · \(inventory.engine.running)/\(inventory.containers.count) running · \(inventory.images.count) images")
                    .font(.caption)
            } else if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else {
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Not connected").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Tabbed Docker panel for one machine.
struct DockerMachineView: View {
    let session: DockerSession
    @State private var tab: DockerTab = .overview
    @State private var query = ""
    @State private var sort: DockerContainerSort = .name
    @State private var pulling = false
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        VStack(spacing: 0) {
            if session.isReady {
                DockerTabBar(selection: $tab)
                Divider()
            }
            content
        }
        .background(Theme.pageBackground)
        .navigationTitle(session.machine.displayName)
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .findShortcut()
        .toolbar { toolbar }
        .sheet(isPresented: $pulling) { DockerPullSheet(session: session) }
        .deleteConfirmation($pendingDelete)
        .onAppear { session.addViewer() }
        .onDisappear { session.removeViewer() }
    }

    private func confirmPrune(_ target: String, _ what: String) {
        pendingDelete = .ask(title: "Prune \(target.capitalized)",
                             message: "Docker removes \(what) on \(session.machine.displayName).",
                             confirmTitle: "Prune") {
            Task { await session.prune(target == "system" ? "system" : target) }
        }
    }

    private var subtitle: String {
        if session.isReady {
            let engine = session.inventory.engine
            return "Docker \(engine.version) · \(engine.running) running"
        }
        return session.error == nil ? "Connecting…" : "Not connected"
    }

    @ViewBuilder private var content: some View {
        if session.isReady {
            switch tab {
            case .overview: DockerOverviewTab(session: session)
            case .containers: DockerContainersTab(session: session, query: query, sort: sort)
            case .compose: DockerComposeTab(session: session, query: query)
            case .images: DockerImagesTab(session: session, query: query)
            case .volumes: DockerVolumesTab(session: session, query: query)
            case .networks: DockerNetworksTab(session: session, query: query)
            case .events: DockerEventsTab(session: session, query: query)
            }
        } else {
            ScrollView {
                DockerConnectionPanel(session: session).padding(Theme.pagePadding)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if session.isReady {
            if tab == .containers {
                ToolbarItem {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(DockerContainerSort.allCases) { option in Text(option.title).tag(option) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
            }
            if tab == .images {
                ToolbarItem { Button("Pull Image", systemImage: "square.and.arrow.down") { pulling = true } }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { session.refreshNow() }
                    .disabled(session.busy)
            }
            ToolbarItem {
                Menu {
                    Button("Prune System", systemImage: "trash") { confirmPrune("system", "stopped containers, unused networks, dangling images and the build cache") }
                    Button("Prune Images") { confirmPrune("image", "dangling images") }
                    Button("Prune Containers") { confirmPrune("container", "stopped containers") }
                    Button("Prune Volumes") { confirmPrune("volume", "volumes no container uses") }
                    Button("Prune Networks") { confirmPrune("network", "networks no container uses") }
                    Divider()
                    Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") { Task { await session.retry() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

/// Connect / Detect Engine / Load Data / Ready steps with the diagnostic log.
struct DockerConnectionPanel: View {
    let session: DockerSession
    @State private var showLog = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text("Endpoint").font(.caption).foregroundStyle(.secondary)
            Text(verbatim: endpoint).font(.callout)
            steps
            logHeader
            if showLog { logBody }
            Button { Task { await session.retry() } } label: { Text("Retry").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .disabled(session.busy)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var endpoint: String {
        let user = session.machine.identity?.username ?? session.machine.username
        return "\(user)@\(session.machine.host):\(session.machine.port)"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title)
                .foregroundStyle(session.error == nil ? Color.accentColor : Color.red)
            VStack(alignment: .leading) {
                Text(session.machine.displayName).font(.headline)
                Text(session.error ?? "Docker panel")
                    .font(.caption)
                    .foregroundStyle(session.error == nil ? Color.secondary : Color.red)
            }
        }
    }

    private var steps: some View {
        HStack(spacing: 10) {
            ForEach(DockerSession.Step.allCases, id: \.rawValue) { step in
                stepChip(step)
            }
        }
    }

    private func stepChip(_ step: DockerSession.Step) -> some View {
        let state = session.steps[step] ?? .pending
        let icon: String
        let tint: Color
        switch state {
        case .done: icon = "checkmark.circle.fill"; tint = .green
        case .failed: icon = "xmark.circle.fill"; tint = .red
        case .running: icon = "circle.dotted"; tint = .accentColor
        case .pending: icon = "circle"; tint = .secondary
        }
        return Label(step.title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var logHeader: some View {
        HStack {
            Text("Connection Log").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(session.log.count) Events").font(.caption2).foregroundStyle(.secondary)
            Button(showLog ? "Hide" : "Show") { showLog.toggle() }.controlSize(.small)
        }
    }

    private var logBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.log) { line in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(line.category == "Error" ? Color.red : Color.accentColor)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    Text("[\(line.time.formatted(date: .omitted, time: .standard))] [\(line.category)] \(line.text)")
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DockerPullSheet: View {
    let session: DockerSession
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""
    @State private var output = ""
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pull Image").font(.headline)
                Spacer()
            }
            .padding(14)
            Divider()
            Form {
                TextField("Reference", text: $reference, prompt: Text("nginx:latest"))
                if !output.isEmpty {
                    Section("Output") {
                        Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Pull") { pull() }
                    .buttonStyle(.borderedProminent)
                    .disabled(reference.isEmpty || running)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 420)
    }

    private func pull() {
        running = true
        let name = reference
        Task {
            output = await session.pull(name)
            running = false
        }
    }
}
