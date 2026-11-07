import SwiftUI

enum DockerContainerSort: String, CaseIterable, Identifiable {
    case name, state, cpu, memory, created
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .state: "State"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .created: "Created"
        }
    }
}

enum DockerStateFilter: String, CaseIterable, Identifiable {
    case all, running, stopped, paused
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct DockerContainersTab: View {
    let session: DockerSession
    let query: String
    let sort: DockerContainerSort
    @State private var filter: DockerStateFilter = .all
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DockerFilterChips(options: DockerStateFilter.allCases.map { ($0.title, $0) }, selection: $filter)
                if rows.isEmpty {
                    ContentUnavailableView("No containers", systemImage: "shippingbox",
                                           description: Text("Nothing matches this filter."))
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .card()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400, maximum: 560), spacing: 14)], spacing: 14) {
                        ForEach(rows) { container in
                            NavigationLink(value: DockerRoute.container(session.machine.id, container.id)) {
                                DockerContainerCard(container: container, stats: session.inventory.stats(for: container))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { DockerContainerMenu(session: session, container: container, pendingDelete: $pendingDelete) }
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .deleteConfirmation($pendingDelete)
    }

    private var rows: [DockerContainer] {
        let all = session.inventory.containers
        let filtered = all.filter { container in
            switch filter {
            case .all: true
            case .running: container.state == "running"
            case .stopped: container.state == "exited" || container.state == "created" || container.state == "dead"
            case .paused: container.state == "paused"
            }
        }
        let searched = query.isEmpty ? filtered : filtered.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.image.localizedCaseInsensitiveContains(query) || $0.project.localizedCaseInsensitiveContains(query)
        }
        return sorted(searched)
    }

    private func sorted(_ items: [DockerContainer]) -> [DockerContainer] {
        switch sort {
        case .name: items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .state: items.sorted { ($0.state, $0.name) < ($1.state, $1.name) }
        case .created: items.sorted { $0.createdAt > $1.createdAt }
        case .cpu: items.sorted { cpu($0) > cpu($1) }
        case .memory: items.sorted { memory($0) > memory($1) }
        }
    }

    private func cpu(_ container: DockerContainer) -> Double { session.inventory.stats(for: container)?.cpu ?? 0 }
    private func memory(_ container: DockerContainer) -> Int64 { session.inventory.stats(for: container)?.memoryUsed ?? 0 }
}

struct DockerContainerMenu: View {
    let session: DockerSession
    let container: DockerContainer
    @Binding var pendingDelete: DeleteRequest?
    @Environment(SessionManager.self) private var sessions
    @Environment(AppState.self) private var state

    var body: some View {
        if container.isRunning {
            Button("Open Shell", systemImage: "terminal") {
                let terminal = sessions.openTerminal(session.machine, command: session.shellCommand(for: container),
                                                     title: "\(session.machine.displayName) · \(container.name)")
                state.selection = .terminalSession(terminal.id)
            }
            Divider()
            Button("Stop", systemImage: "stop.fill") { Task { await session.container("stop", container) } }
            Button("Restart", systemImage: "arrow.clockwise") { Task { await session.container("restart", container) } }
            Button("Pause", systemImage: "pause.fill") { Task { await session.container("pause", container) } }
        } else if container.state == "paused" {
            Button("Resume", systemImage: "play.fill") { Task { await session.container("unpause", container) } }
        } else {
            Button("Start", systemImage: "play.fill") { Task { await session.container("start", container) } }
        }
        Divider()
        Button("Remove", systemImage: "trash", role: .destructive) {
            pendingDelete = .confirm(kind: "Container", name: container.name,
                                     note: "It is force-removed on \(session.machine.displayName).",
                                     confirmTitle: "Remove") {
                Task { await session.container("rm -f", container) }
            }
        }
    }
}

/// Container card: state, image, compose line, published ports and the live gauges.
struct DockerContainerCard: View {
    let container: DockerContainer
    let stats: DockerStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(container.name, systemImage: "shippingbox.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Circle().fill(container.stateColor).frame(width: 8, height: 8)
                Text(container.status).font(.callout)
            }
            Text(container.image).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            if !container.composeLine.isEmpty {
                Label(container.composeLine, systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !container.ports.isEmpty {
                DockerPortRow(ports: container.ports)
            }
            Divider()
            metrics
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 18) {
            RingGauge(percent: stats?.cpu ?? 0, label: "CPU", size: 48)
            RingGauge(percent: stats?.memoryPercent ?? 0, label: "RAM", size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text("Network").font(.caption).foregroundStyle(.secondary)
                DockerIOValue(icon: "arrow.down.circle", bytes: stats?.netRx ?? 0)
                DockerIOValue(icon: "arrow.up.circle", bytes: stats?.netTx ?? 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Block IO").font(.caption).foregroundStyle(.secondary)
                DockerIOValue(icon: "r.circle", bytes: stats?.blockRead ?? 0)
                DockerIOValue(icon: "w.circle", bytes: stats?.blockWrite ?? 0)
            }
            Spacer()
        }
    }
}

/// Wrapping row of published-port chips.
struct DockerPortRow: View {
    let ports: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(ports, id: \.self) { port in
                Text(port)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.cyan.opacity(0.14), in: Capsule())
            }
        }
    }
}

/// Minimal wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
