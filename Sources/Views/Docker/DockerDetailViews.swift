import SwiftUI

// MARK: - Container

struct DockerContainerDetailView: View {
    let session: DockerSession
    let containerID: String
    @State private var logText = ""
    @State private var loadingLogs = false
    @State private var inspectText: String?
    @State private var pendingDelete: DeleteRequest?

    private var container: DockerContainer? {
        session.inventory.containers.first { $0.id == containerID }
    }

    var body: some View {
        ScrollView {
            if let container {
                VStack(spacing: 14) {
                    DockerContainerHeader(session: session, container: container,
                                          stats: session.inventory.stats(for: container),
                                          pendingDelete: $pendingDelete)
                    DockerContainerFacts(container: container)
                    if !container.ports.isEmpty {
                        DockerCard(title: "Ports", icon: "network", tint: .cyan) {
                            DockerPortRow(ports: container.ports)
                        }
                    }
                    DockerContainerConnections(container: container)
                    if !container.labels.isEmpty {
                        DockerCard(title: "Labels", icon: "tag", tint: .orange) {
                            ForEach(container.labels.keys.sorted(), id: \.self) { key in
                                DockerRow(label: key, value: container.labels[key] ?? "", monospaced: true)
                            }
                        }
                    }
                    logs(container)
                }
                .padding(Theme.pagePadding)
            } else {
                ContentUnavailableView("Container is gone", systemImage: "shippingbox")
                    .padding(Theme.pagePadding)
            }
        }
        .background(Theme.pageBackground)
        .navigationTitle(container?.name ?? "Container")
        .navigationSubtitle(container?.status ?? "")
        .deleteConfirmation($pendingDelete)
        .onAppear { session.addViewer() }
        .onDisappear { session.removeViewer() }
        .task(id: containerID) { await reloadLogs() }
        .sheet(isPresented: Binding(get: { inspectText != nil }, set: { if !$0 { inspectText = nil } })) {
            DockerTextSheet(title: "Inspect", text: inspectText ?? "")
        }
    }

    private func logs(_ container: DockerContainer) -> some View {
        DockerCard(title: "Logs", icon: "doc.text", tint: .indigo, trailing: "last 300 lines") {
            HStack {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await reloadLogs() } }
                    .disabled(loadingLogs)
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                Button("Inspect", systemImage: "curlybraces") {
                    Task { inspectText = await session.inspect(container.id) }
                }
                Spacer()
                if loadingLogs { ProgressView().controlSize(.small) }
            }
            ScrollView {
                Text(logText.isEmpty ? "No output." : logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func reloadLogs() async {
        guard let container else { return }
        loadingLogs = true
        logText = await session.logs(container)
        loadingLogs = false
    }
}

struct DockerContainerHeader: View {
    let session: DockerSession
    let container: DockerContainer
    let stats: DockerStats?
    @Binding var pendingDelete: DeleteRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(container.stateColor)
                    .frame(width: 52, height: 52)
                    .background(container.stateColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(container.name).font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        DockerTagBadge(text: container.state, tint: container.stateColor)
                        Text(container.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(container.image).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                RingGauge(percent: stats?.cpu ?? 0, label: "CPU", size: 48)
                RingGauge(percent: stats?.memoryPercent ?? 0, label: "RAM", size: 48)
            }
            HStack(spacing: 10) {
                if container.isRunning {
                    Button("Stop", systemImage: "stop.fill") { Task { await session.container("stop", container) } }
                    Button("Restart", systemImage: "arrow.clockwise") { Task { await session.container("restart", container) } }
                    Button("Pause", systemImage: "pause.fill") { Task { await session.container("pause", container) } }
                } else if container.state == "paused" {
                    Button("Resume", systemImage: "play.fill") { Task { await session.container("unpause", container) } }
                } else {
                    Button("Start", systemImage: "play.fill") { Task { await session.container("start", container) } }
                }
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive) {
                    pendingDelete = .confirm(kind: "Container", name: container.name,
                                             note: "It is force-removed on \(session.machine.displayName).",
                                             confirmTitle: "Remove") {
                        Task { await session.container("rm -f", container) }
                    }
                }
            }
            .disabled(session.busy)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct DockerContainerFacts: View {
    let container: DockerContainer

    var body: some View {
        DockerCard(title: "Container", icon: "info.circle", tint: .accentColor) {
            DockerRow(label: "ID", value: container.shortID, monospaced: true)
            DockerRow(label: "Image", value: container.image, monospaced: true)
            DockerRow(label: "Created", value: container.createdAt)
            DockerRow(label: "Uptime", value: container.runningFor)
            if !container.project.isEmpty {
                DockerRow(label: "Compose Project", value: container.project)
                DockerRow(label: "Service", value: container.service)
            }
            DockerRow(label: "Command", value: container.command, monospaced: true)
        }
    }
}

struct DockerContainerConnections: View {
    let container: DockerContainer

    var body: some View {
        DockerCard(title: "Networks & Mounts", icon: "point.3.connected.trianglepath.dotted", tint: .green) {
            DockerRow(label: "Networks", value: container.networks.joined(separator: ", "))
            DockerRow(label: "Mounts", value: container.mounts.isEmpty ? "-" : container.mounts.joined(separator: ", "), monospaced: true)
        }
    }
}

// MARK: - Image

struct DockerImageDetailView: View {
    let session: DockerSession
    let imageID: String
    @State private var inspectText: String?
    @State private var pendingDelete: DeleteRequest?

    private var image: DockerImage? { session.inventory.images.first { $0.id == imageID } }

    var body: some View {
        ScrollView {
            if let image {
                VStack(spacing: 14) {
                    DockerCard(title: "Image", icon: "opticaldiscdrive", tint: .accentColor) {
                        DockerRow(label: "Repository", value: image.repository, monospaced: true)
                        DockerRow(label: "Tag", value: image.tag, monospaced: true)
                        DockerRow(label: "ID", value: image.shortID, monospaced: true)
                        DockerRow(label: "Size", value: Format.precise(image.size))
                        DockerRow(label: "Created", value: image.createdSince)
                        if !image.digest.isEmpty, image.digest != "<none>" {
                            DockerRow(label: "Digest", value: image.digest, monospaced: true)
                        }
                    }
                    DockerCard(title: "Used By", icon: "shippingbox", tint: .green) {
                        if image.usedBy.isEmpty {
                            Text("No containers use this image.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(image.usedBy, id: \.self) { name in
                            Label(name, systemImage: "shippingbox").font(.callout)
                        }
                    }
                    HStack {
                        Button("Inspect", systemImage: "curlybraces") {
                            Task { inspectText = await session.inspect(image.id) }
                        }
                        Spacer()
                        Button("Remove Image", systemImage: "trash", role: .destructive) {
                            pendingDelete = .confirm(kind: "Image", name: image.reference,
                                                     note: image.usedBy.isEmpty ? nil : "It is used by \(image.usedBy.count) container(s) and will be force-removed.",
                                                     confirmTitle: "Remove") {
                                Task { await session.removeImage(image, force: !image.usedBy.isEmpty) }
                            }
                        }
                    }
                    .disabled(session.busy)
                }
                .padding(Theme.pagePadding)
            } else {
                ContentUnavailableView("Image is gone", systemImage: "opticaldiscdrive").padding(Theme.pagePadding)
            }
        }
        .background(Theme.pageBackground)
        .navigationTitle(image?.reference ?? "Image")
        .deleteConfirmation($pendingDelete)
        .onAppear { session.addViewer() }
        .onDisappear { session.removeViewer() }
        .sheet(isPresented: Binding(get: { inspectText != nil }, set: { if !$0 { inspectText = nil } })) {
            DockerTextSheet(title: "Inspect", text: inspectText ?? "")
        }
    }
}

// MARK: - Volume

struct DockerVolumeDetailView: View {
    let session: DockerSession
    let volumeName: String
    @State private var pendingDelete: DeleteRequest?

    private var volume: DockerVolume? { session.inventory.volumes.first { $0.name == volumeName } }

    var body: some View {
        ScrollView {
            if let volume {
                VStack(spacing: 14) {
                    DockerCard(title: "Volume", icon: "externaldrive", tint: .accentColor) {
                        DockerRow(label: "Name", value: volume.name, monospaced: true)
                        DockerRow(label: "Driver", value: volume.driver)
                        DockerRow(label: "Scope", value: volume.scope)
                        DockerRow(label: "Mountpoint", value: volume.mountpoint, monospaced: true)
                    }
                    DockerCard(title: "Used By", icon: "shippingbox", tint: .green) {
                        if volume.usedBy.isEmpty {
                            Text("No containers mount this volume.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(volume.usedBy, id: \.self) { name in
                            Label(name, systemImage: "shippingbox").font(.callout)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Remove Volume", systemImage: "trash", role: .destructive) {
                            pendingDelete = .confirm(kind: "Volume", name: volume.name,
                                                     note: "Its data on \(session.machine.displayName) is removed.",
                                                     confirmTitle: "Remove") {
                                Task { await session.removeVolume(volume) }
                            }
                        }
                        .disabled(session.busy || !volume.usedBy.isEmpty)
                    }
                }
                .padding(Theme.pagePadding)
            } else {
                ContentUnavailableView("Volume is gone", systemImage: "externaldrive").padding(Theme.pagePadding)
            }
        }
        .background(Theme.pageBackground)
        .navigationTitle(volumeName)
        .deleteConfirmation($pendingDelete)
        .onAppear { session.addViewer() }
        .onDisappear { session.removeViewer() }
    }
}

// MARK: - Network

struct DockerNetworkDetailView: View {
    let session: DockerSession
    let networkID: String
    @State private var inspectText: String?
    @State private var pendingDelete: DeleteRequest?

    private var network: DockerNetwork? { session.inventory.networks.first { $0.id == networkID } }

    var body: some View {
        ScrollView {
            if let network {
                VStack(spacing: 14) {
                    DockerCard(title: "Network", icon: "globe", tint: .accentColor) {
                        DockerRow(label: "Name", value: network.name)
                        DockerRow(label: "ID", value: network.shortID, monospaced: true)
                        DockerRow(label: "Driver", value: network.driver.isEmpty ? "null" : network.driver)
                        DockerRow(label: "Scope", value: network.scope)
                        DockerRow(label: "Subnet", value: network.subnet.isEmpty ? "-" : network.subnet, monospaced: true)
                        DockerRow(label: "Gateway", value: network.gateway.isEmpty ? "-" : network.gateway, monospaced: true)
                        DockerRow(label: "Internal", value: network.isInternal ? "Yes" : "No")
                        DockerRow(label: "Attachable", value: network.isAttachable ? "Yes" : "No")
                    }
                    DockerCard(title: "Connected Containers", icon: "shippingbox", tint: .green) {
                        if network.containerNames.isEmpty {
                            Text("No containers are attached.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(network.containerNames, id: \.self) { name in
                            Label(name, systemImage: "shippingbox").font(.callout)
                        }
                    }
                    HStack {
                        Button("Inspect", systemImage: "curlybraces") {
                            Task { inspectText = await session.inspect(network.id) }
                        }
                        Spacer()
                        Button("Remove Network", systemImage: "trash", role: .destructive) {
                            pendingDelete = .confirm(kind: "Network", name: network.name,
                                                     note: "It is removed on \(session.machine.displayName).",
                                                     confirmTitle: "Remove") {
                                Task { await session.removeNetwork(network) }
                            }
                        }
                        .disabled(network.isBuiltIn || !network.containerNames.isEmpty)
                    }
                    .disabled(session.busy)
                }
                .padding(Theme.pagePadding)
            } else {
                ContentUnavailableView("Network is gone", systemImage: "globe").padding(Theme.pagePadding)
            }
        }
        .background(Theme.pageBackground)
        .navigationTitle(network?.name ?? "Network")
        .deleteConfirmation($pendingDelete)
        .onAppear { session.addViewer() }
        .onDisappear { session.removeViewer() }
        .sheet(isPresented: Binding(get: { inspectText != nil }, set: { if !$0 { inspectText = nil } })) {
            DockerTextSheet(title: "Inspect", text: inspectText ?? "")
        }
    }
}

// MARK: - Compose project

struct DockerComposeDetailView: View {
    let session: DockerSession
    let projectName: String
    @State private var pendingDelete: DeleteRequest?

    private var project: DockerCompose? { session.inventory.composes.first { $0.name == projectName } }
    private var containers: [DockerContainer] {
        session.inventory.containers.filter { $0.project == projectName }
    }

    var body: some View {
        ScrollView {
            if let project {
                VStack(spacing: 14) {
                    DockerCard(title: "Project", icon: "square.stack.3d.up", tint: .accentColor) {
                        DockerRow(label: "Name", value: project.name)
                        DockerRow(label: "Status", value: project.status)
                        DockerRow(label: "Services", value: "\(project.services)")
                        ForEach(project.configFileList, id: \.self) { file in
                            DockerRow(label: "Config", value: file, monospaced: true)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Up", systemImage: "play.fill") { Task { await session.compose("up -d", project) } }
                        Button("Restart", systemImage: "arrow.clockwise") { Task { await session.compose("restart", project) } }
                        Button("Pull", systemImage: "square.and.arrow.down") { Task { await session.compose("pull", project) } }
                        Spacer()
                        Button("Down", systemImage: "stop.fill", role: .destructive) {
                            pendingDelete = .ask(title: "Bring Project Down",
                                                 message: "“\(project.name)” is stopped and its containers are removed on \(session.machine.displayName).",
                                                 confirmTitle: "Down") {
                                Task { await session.compose("down", project) }
                            }
                        }
                    }
                    .disabled(session.busy)
                    DockerCard(title: "Containers", icon: "shippingbox", tint: .green) {
                        if containers.isEmpty {
                            Text("This project has no containers right now.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(containers) { container in
                            NavigationLink(value: DockerRoute.container(session.machine.id, container.id)) {
                                HStack(spacing: 8) {
                                    Circle().fill(container.stateColor).frame(width: 7, height: 7)
                                    Text(container.name).font(.callout)
                                    Spacer()
                                    Text(container.status).font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Theme.pagePadding)
            } else {
                ContentUnavailableView("Project is gone", systemImage: "square.stack.3d.up").padding(Theme.pagePadding)
            }
        }
        .background(Theme.pageBackground)
        .navigationTitle(projectName)
        .deleteConfirmation($pendingDelete)
        .onAppear { session.addViewer() }
        .onDisappear { session.removeViewer() }
    }
}

/// Scrollable monospaced output (docker inspect).
struct DockerTextSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .padding(14)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 760, height: 560)
    }
}
