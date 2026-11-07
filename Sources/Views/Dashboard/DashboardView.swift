import SwiftUI
import SwiftData

struct DashboardView: View {
    @Query(sort: \Machine.name) private var machines: [Machine]
    @Environment(DashboardStore.self) private var store
    @Environment(AppState.self) private var state
    @Environment(SessionManager.self) private var sessions
    @State private var tagFilter: String? = nil
    @State private var showGlobal = false
    @State private var showOrder = false
    /// Status pages, and the Docker pages their Docker card opens.
    @State private var path = NavigationPath()

    private var shown: [Machine] {
        machines.filter(\.showInDashboard).filtered(by: state).filter { m in
            switch tagFilter { case nil: true; case "": m.tags.isEmpty; case let t?: m.tags.contains(t) }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Page(title: "Dashboard") {
                if UserDefaults.standard.object(forKey: "showTagFilters") as? Bool ?? true {
                    TagFilterBar(tags: Array(Set(machines.flatMap(\.tags))).sorted(), selection: $tagFilter)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).card()
                }
                HStack(spacing: 14) {
                    summary("Total", count: shown.count, color: .accentColor)
                    summary("Online", count: store.onlineCount, color: .green)
                    summary("Offline", count: store.offlineCount, color: .red)
                }
                if shown.isEmpty {
                    ContentUnavailableView("No machines on the dashboard", systemImage: "gauge.with.dots.needle.33percent",
                                           description: Text("Add a machine and enable “Show Status in Dashboard”."))
                        .frame(maxWidth: .infinity, minHeight: 240).card()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 520), spacing: 14)], spacing: 14) {
                        ForEach(shown) { machine in
                            MachineStatusCard(monitor: store.monitor(for: machine))
                                .onTapGesture { path.append(machine) }
                                .contextMenu {
                                    Button("Start Terminal", systemImage: "terminal") { state.selection = .terminalSession(sessions.openTerminal(machine).id) }
                                    Button("Start SFTP", systemImage: "folder") { state.selection = .sftpSession(sessions.openSFTP(machine).id) }
                                }
                        }
                    }
                }
            }
            .navigationDestination(for: Machine.self) { StatusDetailView(monitor: store.monitor(for: $0)) }
            .navigationDestination(for: DockerRoute.self) { DockerRouter(route: $0) }
            .searchable(text: Bindable(state).searchText)
            .findShortcut()
        }
        .toolbar {
            ToolbarItem { Button("Global View", systemImage: "globe") { showGlobal = true } }
            ToolbarItem { Button("Sort", systemImage: "arrow.up.arrow.down") { showOrder = true } }
            ToolbarItem {
                Menu {
                    Button("Refresh All") { store.refreshAll() }
                    Button("Refresh Failed Only") { store.refreshAll(failedOnly: true) }
                } label: { Image(systemName: "arrow.counterclockwise") }
            }
        }
        .sheet(isPresented: $showGlobal) { GlobalViewSheet(monitors: shown.map { store.monitor(for: $0) }) }
        .sheet(isPresented: $showOrder) { DashboardOrderSheet(machines: shown) }
        .onAppear { store.sync(with: machines) }
        .onChange(of: machines.map { "\($0.id)\($0.showInDashboard)" }) { store.sync(with: machines) }
    }

    private func summary(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(verbatim: "\(count)").font(.title2.weight(.semibold)).monospacedDigit()
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

struct MachineStatusCard: View {
    let monitor: MachineMonitor

    var body: some View {
        let s = monitor.status
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(monitor.location?.flag ?? "").font(.body)
                Text(monitor.machine.displayName).font(.body.weight(.semibold)).lineLimit(1)
                Spacer()
                if case .offline(let why) = monitor.state {
                    Text(why).font(.caption2).foregroundStyle(.red).lineLimit(1).help(why)
                }
                if monitor.state == .connecting { ProgressView().controlSize(.mini) }
                LatencyBadge(ms: monitor.latencyMs, online: monitor.isOnline)
            }
            if let s {
                HStack(spacing: 14) {
                    Chip(icon: "cpu", text: "\(s.snapshot.coreCount) Cores")
                    Chip(icon: "memorychip", text: Format.short(s.snapshot.memTotal))
                    Chip(icon: "internaldrive", text: Format.short(s.totalDiskBytes))
                    Chip(icon: "clock", text: Format.uptime(s.snapshot.uptime))
                    if let t = s.snapshot.temperatureC {
                        Chip(icon: "thermometer.medium", text: UserDefaults.standard.string(forKey: "temperatureUnit") == "fahrenheit" ? "\(Int(t * 9 / 5 + 32))°F" : "\(Int(t))°C")
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: 18) {
                    RingGauge(percent: s.cpu.total, label: "CPU")
                    RingGauge(percent: s.memPercent, label: "RAM")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Network").font(.caption).foregroundStyle(.secondary)
                        RateLine(icon: "arrow.down.circle", bytesPerSec: s.network.rx)
                        RateLine(icon: "arrow.up.circle", bytesPerSec: s.network.tx)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Disk").font(.caption).foregroundStyle(.secondary)
                        RateLine(icon: "arrow.down.to.line.circle", bytesPerSec: s.diskIO.rx)
                        RateLine(icon: "arrow.up.to.line.circle", bytesPerSec: s.diskIO.tx)
                    }
                    Spacer()
                }
            } else {
                Text(monitor.machine.host).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 18) { RingGauge(percent: 0, label: "CPU"); RingGauge(percent: 0, label: "RAM"); Spacer() }.opacity(0.4)
            }
        }
        .padding(14).card().contentShape(Rectangle())
    }
}

struct DashboardOrderSheet: View {
    let machines: [Machine]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Text("Dashboard Order").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            Divider()
            List(machines) { m in
                Label { VStack(alignment: .leading) { Text(m.displayName); Text(m.host).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "server.rack") }
            }
            Text("Machines are ordered by the sort option in the Machines view.").font(.caption).foregroundStyle(.secondary).padding(8)
            Divider()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 460, height: 420)
    }
}
