import SwiftUI

// MARK: - Compose

struct DockerComposeTab: View {
    let session: DockerSession
    let query: String
    @State private var expanded: Set<String> = []
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if rows.isEmpty {
                    DockerEmptyState(title: "No compose projects", icon: "square.stack.3d.up",
                                     message: "Projects started with docker compose appear here.")
                } else {
                    ForEach(rows) { project in
                        DockerComposeCard(session: session, project: project,
                                          expanded: expanded.contains(project.name),
                                          pendingDelete: $pendingDelete) {
                            toggle(project.name)
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .deleteConfirmation($pendingDelete)
    }

    private var rows: [DockerCompose] {
        let all = session.inventory.composes
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func toggle(_ name: String) {
        if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
    }
}

struct DockerComposeCard: View {
    let session: DockerSession
    let project: DockerCompose
    let expanded: Bool
    @Binding var pendingDelete: DeleteRequest?
    let onToggle: () -> Void

    private var containers: [DockerContainer] {
        session.inventory.containers.filter { project.containerIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: DockerRoute.compose(session.machine.id, project.name)) {
                HStack {
                    Label(project.name, systemImage: "square.stack.3d.up.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            DockerRow(label: "Status", value: project.status)
            DockerRow(label: "Services", value: "\(project.services)")
            ForEach(project.configFileList, id: \.self) { file in
                Text(file).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Divider()
            Button(action: onToggle) {
                HStack {
                    Label("Show Containers", systemImage: expanded ? "chevron.down.circle" : "chevron.right.circle")
                    Spacer()
                    Text("\(containers.count)").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(containers) { container in
                    NavigationLink(value: DockerRoute.container(session.machine.id, container.id)) {
                        HStack(spacing: 8) {
                            Circle().fill(container.stateColor).frame(width: 7, height: 7)
                            Text(container.name).font(.callout)
                            Spacer()
                            Text(container.status).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contextMenu {
            Button("Up", systemImage: "play.fill") { Task { await session.compose("up -d", project) } }
            Button("Restart", systemImage: "arrow.clockwise") { Task { await session.compose("restart", project) } }
            Button("Down", systemImage: "stop.fill", role: .destructive) {
                pendingDelete = .ask(title: "Bring Project Down",
                                     message: "“\(project.name)” is stopped and its containers are removed on \(session.machine.displayName).",
                                     confirmTitle: "Down") {
                    Task { await session.compose("down", project) }
                }
            }
        }
    }
}

// MARK: - Images

struct DockerImagesTab: View {
    let session: DockerSession
    let query: String
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if rows.isEmpty {
                    DockerEmptyState(title: "No images available", icon: "opticaldiscdrive",
                                     message: "Pull an image to get started.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 520), spacing: 14)], spacing: 14) {
                        ForEach(rows) { image in
                            NavigationLink(value: DockerRoute.image(session.machine.id, image.id)) {
                                DockerImageCard(image: image)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    pendingDelete = .confirm(kind: "Image", name: image.reference,
                                                             note: image.usedBy.isEmpty ? nil : "It is used by \(image.usedBy.count) container(s) and will be force-removed.",
                                                             confirmTitle: "Remove") {
                                        Task { await session.removeImage(image, force: !image.usedBy.isEmpty) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .deleteConfirmation($pendingDelete)
    }

    private var rows: [DockerImage] {
        let all = session.inventory.images
        return query.isEmpty ? all : all.filter { $0.reference.localizedCaseInsensitiveContains(query) }
    }
}

struct DockerImageCard: View {
    let image: DockerImage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(image.reference, systemImage: "shippingbox.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                Text(image.shortID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                DockerUsageBadge(count: image.usedBy.count)
            }
            HStack {
                Text("Created \(image.createdSince)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Format.precise(image.size)).font(.callout.weight(.medium)).monospacedDigit()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }
}

// MARK: - Volumes

struct DockerVolumesTab: View {
    let session: DockerSession
    let query: String
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if rows.isEmpty {
                    DockerEmptyState(title: "No volumes available", icon: "externaldrive",
                                     message: "Named volumes created by containers appear here.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 520), spacing: 14)], spacing: 14) {
                        ForEach(rows) { volume in
                            NavigationLink(value: DockerRoute.volume(session.machine.id, volume.name)) {
                                DockerVolumeCard(volume: volume)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    pendingDelete = .confirm(kind: "Volume", name: volume.name,
                                                             note: "Its data on \(session.machine.displayName) is removed.",
                                                             confirmTitle: "Remove") {
                                        Task { await session.removeVolume(volume) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .deleteConfirmation($pendingDelete)
    }

    private var rows: [DockerVolume] {
        let all = session.inventory.volumes
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

struct DockerVolumeCard: View {
    let volume: DockerVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(volume.name, systemImage: "externaldrive.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                Text(volume.driver).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                DockerUsageBadge(count: volume.usedBy.count)
            }
            Text(volume.mountpoint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }
}

// MARK: - Networks

struct DockerNetworksTab: View {
    let session: DockerSession
    let query: String
    @State private var pendingDelete: DeleteRequest?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if rows.isEmpty {
                    DockerEmptyState(title: "No networks available", icon: "globe", message: "Docker networks appear here.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 520), spacing: 14)], spacing: 14) {
                        ForEach(rows) { network in
                            NavigationLink(value: DockerRoute.network(session.machine.id, network.id)) {
                                DockerNetworkCard(network: network)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    pendingDelete = .confirm(kind: "Network", name: network.name,
                                                             note: "It is removed on \(session.machine.displayName).",
                                                             confirmTitle: "Remove") {
                                        Task { await session.removeNetwork(network) }
                                    }
                                }
                                .disabled(network.isBuiltIn)
                            }
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .deleteConfirmation($pendingDelete)
    }

    private var rows: [DockerNetwork] {
        let all = session.inventory.networks
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

struct DockerNetworkCard: View {
    let network: DockerNetwork

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(network.name, systemImage: "globe")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Text(network.driver.isEmpty ? "null" : network.driver)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if network.isBuiltIn { DockerTagBadge(text: "Built-in") }
                Spacer()
                DockerUsageBadge(count: network.containerNames.count)
            }
            DockerRow(label: "Subnet", value: network.subnet.isEmpty ? "-" : network.subnet, monospaced: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }
}

// MARK: - Events

struct DockerEventsTab: View {
    let session: DockerSession
    let query: String
    @State private var filter = "all"

    private let options = [("All", "all"), ("Containers", "container"), ("Images", "image"),
                           ("Volumes", "volume"), ("Networks", "network")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    DockerFilterChips(options: options, selection: $filter)
                    Spacer()
                    Button("Clear", systemImage: "trash") { session.clearEvents() }
                        .controlSize(.small)
                        .disabled(session.events.isEmpty)
                }
                if rows.isEmpty {
                    DockerEmptyState(title: "Waiting for Docker events", icon: "clock.arrow.circlepath",
                                     message: "Lifecycle events appear here live while this panel is open.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows.reversed()) { event in
                            DockerEventRow(event: event)
                            Divider()
                        }
                    }
                    .card()
                }
            }
            .padding(Theme.pagePadding)
        }
        .onAppear { session.startEvents() }
        .onDisappear { session.stopEvents() }
    }

    private var rows: [DockerEvent] {
        let all = filter == "all" ? session.events : session.events.filter { $0.type == filter }
        return query.isEmpty ? all : all.filter {
            $0.actor.localizedCaseInsensitiveContains(query) || $0.action.localizedCaseInsensitiveContains(query)
        }
    }
}

struct DockerEventRow: View {
    let event: DockerEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.icon).foregroundStyle(.secondary).frame(width: 18)
            Text(event.time.formatted(date: .omitted, time: .standard))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            DockerTagBadge(text: event.action, tint: tint)
            Text(event.actor).font(.callout).lineLimit(1)
            Spacer()
            Text(event.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var tint: Color {
        switch event.action {
        case "start", "create", "pull", "connect": .green
        case "die", "kill", "stop", "destroy", "delete", "disconnect": .red
        case "pause": .orange
        default: .secondary
        }
    }
}

struct DockerEmptyState: View {
    let title: String
    let icon: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(message))
            .frame(maxWidth: .infinity, minHeight: 260)
            .card()
    }
}
