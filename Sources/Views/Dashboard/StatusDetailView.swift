import SwiftUI
import Charts
import MapKit

/// Full machine status page: CPU, load chart, processes, memory, network, IP location, storage.
struct StatusDetailView: View {
    let monitor: MachineMonitor
    var compact = false
    @AppStorage("hideIPInformation") private var hideIP = false
    @Environment(SessionManager.self) private var sessions
    @Environment(AppState.self) private var state
    @Environment(DockerStore.self) private var docker
    @Environment(DashboardStore.self) private var dashboard
    @State private var showProcesses = false
    @State private var showActivity = false

    var body: some View {
        Page(title: monitor.machine.displayName) {
            if let s = monitor.status {
                if compact {
                    VStack(spacing: 14) { header(s); cpuCard(s); loadCard(s); processesCard(s); memoryCard(s); networkCard(s); storageCard(s) }
                } else {
                    header(s)
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 14) {
                            cpuCard(s)
                            loadCard(s)
                            memoryCard(s)
                            // Opens the machine's Docker page in the same stack (DashboardView routes DockerRoute).
                            NavigationLink(value: DockerRoute.machine(monitor.machine.id)) {
                                DockerSummaryCard(session: docker.session(for: monitor.machine, dashboard: dashboard))
                            }
                            .buttonStyle(.plain)
                        }
                        VStack(spacing: 14) {
                            processesCard(s)
                            networkCard(s)
                            if !hideIP { locationCard }
                            storageCard(s)
                        }
                    }
                }
            } else {
                ContentUnavailableView(monitor.state == .connecting ? "Connecting…" : "No data yet", systemImage: "gauge.with.dots.needle.33percent",
                                       description: Text({ if case .offline(let e) = monitor.state { e } else { "Waiting for the first metrics sample." } }()))
                    .frame(maxWidth: .infinity, minHeight: 300).card()
            }
        }
        .onAppear { monitor.processViewers += 1 }
        .onDisappear { monitor.processViewers = max(monitor.processViewers - 1, 0) }
        .sheet(isPresented: $showActivity) {
            NavigationStack {
                AgentActivityView(machineID: monitor.machine.id.uuidString)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showActivity = false } } }
            }
            .frame(minWidth: 620, minHeight: 480)
        }
        .toolbar {
            ToolbarItem { Button("Start Terminal", systemImage: "terminal") { state.selection = .terminalSession(sessions.openTerminal(monitor.machine).id) } }
            ToolbarItem {
                Button("Agent Activity", systemImage: "clock.arrow.circlepath") { showActivity = true }
                    .help("What AI agents did on this machine")
            }
            ToolbarItem { Button("Start SFTP", systemImage: "folder") { state.selection = .sftpSession(sessions.openSFTP(monitor.machine).id) } }
            ToolbarItem {
                Menu {
                    Toggle("Hide IP Information", isOn: $hideIP)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { monitor.start() }
    }

    private func header(_ s: MachineStatus) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 56).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.machine.displayName).font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    Text(s.snapshot.osName.isEmpty ? s.snapshot.kernel : s.snapshot.osName).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.accentColor.opacity(0.12), in: Capsule())
                    Text(s.snapshot.hostname).font(.caption).foregroundStyle(.secondary)
                    LatencyBadge(ms: monitor.latencyMs, online: monitor.isOnline)
                }
            }
            Spacer()
            if !compact {
                RingGauge(percent: s.cpu.total, label: "CPU", size: 50)
                RingGauge(percent: s.memPercent, label: "RAM", size: 50)
                RingGauge(percent: s.diskPercent, label: "Disk", size: 50)
            }
        }
        .padding(16).card()
    }

    private func cardTitle(_ title: String, _ icon: String, _ color: Color) -> some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(color)
    }

    private func cpuCard(_ s: MachineStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("CPU Usage", "cpu", .blue)
            HStack(alignment: .firstTextBaseline) {
                Text("%").font(.caption).foregroundStyle(.secondary) + Text("\(Int(s.cpu.total))").font(.title.weight(.semibold))
                Spacer()
                Text(s.snapshot.kernel).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                ForEach(Array(s.cpu.cores.enumerated()), id: \.offset) { _, pct in
                    RoundedRectangle(cornerRadius: 2).fill(pct > 80 ? Color.red : Color.blue.opacity(0.3 + pct / 140)).frame(height: 8)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    stat("Cores", "\(s.snapshot.coreCount)"); stat("User", pct(s.cpu.user), .blue); stat("System", pct(s.cpu.system), .red)
                    stat("Nice", pct(s.cpu.nice), .green); stat("IOWait", pct(s.cpu.iowait), .purple); stat("Steal", pct(s.cpu.steal), .orange)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity).card()
    }

    private func loadCard(_ s: MachineStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("CPU Load", "waveform.path.ecg", .orange)
            Chart {
                ForEach(Array(s.loadHistory.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.0), y: .value("1m", point.1[0])).foregroundStyle(by: .value("Window", "1m"))
                    LineMark(x: .value("Time", point.0), y: .value("5m", point.1.count > 1 ? point.1[1] : 0)).foregroundStyle(by: .value("Window", "5m"))
                    LineMark(x: .value("Time", point.0), y: .value("15m", point.1.count > 2 ? point.1[2] : 0)).foregroundStyle(by: .value("Window", "15m"))
                }
            }
            .chartForegroundStyleScale(["1m": Color.red, "5m": Color.green, "15m": Color.orange])
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 140)
            HStack { Text("Current Load").font(.caption).foregroundStyle(.secondary); Spacer()
                Text(s.snapshot.load.map { String(format: "%.2f", $0) }.joined(separator: " / ")).font(.caption).monospacedDigit() }
        }
        .padding(14).frame(maxWidth: .infinity).card()
    }

    private func memoryCard(_ s: MachineStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Memory Usage", "memorychip", .purple)
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 12)
                    Circle().trim(from: 0, to: s.memPercent / 100).stroke(.purple, style: .init(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                    Circle().trim(from: s.memPercent / 100, to: min((s.memPercent + Double(s.snapshot.memCached) / Double(max(s.snapshot.memTotal, 1)) * 100) / 100, 1))
                        .stroke(.purple.opacity(0.35), style: .init(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack { Text("Total").font(.caption2).foregroundStyle(.secondary); Text(Format.short(s.snapshot.memTotal)).font(.headline) }
                }
                .frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 8) {
                    legend(.purple, Format.short(s.memUsed), "%\(Int(s.memPercent)) Used")
                    legend(.purple.opacity(0.35), Format.short(s.snapshot.memCached), "Cached")
                    legend(.gray.opacity(0.3), Format.short(s.snapshot.memFree), "Free")
                }
                Spacer()
            }
            HStack { Text("Swap").font(.caption).foregroundStyle(.secondary); Spacer()
                Text(s.snapshot.swapTotal > 0 ? "\(Format.short(s.swapUsed)) / \(Format.short(s.snapshot.swapTotal))" : "N/A").font(.caption) }
        }
        .padding(14).frame(maxWidth: .infinity).card()
    }

    private func processesCard(_ s: MachineStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                cardTitle("Processes", "list.bullet.rectangle", .red)
                Spacer()
                Button("All Processes…") { showProcesses = true }.buttonStyle(.link).font(.caption)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Pid"); Text("Process"); Text("User"); Text("CPU%"); Text("Mem")
                }.font(.caption2.weight(.semibold)).foregroundStyle(.red)
                ForEach(s.snapshot.processes) { p in
                    GridRow {
                        Text(String(p.pid)); Text(p.command).lineLimit(1); Text(p.user).lineLimit(1)
                        Text(String(format: "%.1f", p.cpu)); Text(Format.short(p.rssBytes))
                    }.font(.caption).monospacedDigit()
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
        .sheet(isPresented: $showProcesses) { ProcessesSheet(monitor: monitor) }
    }

    private func networkCard(_ s: MachineStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                cardTitle("Network Usage", "network", .teal); Spacer()
                Text(s.snapshot.physicalInterfaces.joined(separator: " + ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    RateLine(icon: "arrow.down.circle", bytesPerSec: s.network.rx)
                    RateLine(icon: "arrow.up.circle", bytesPerSec: s.network.tx)
                }
                Spacer()
                if !s.snapshot.physicalInterfaces.isEmpty {
                    let c = s.snapshot.traffic
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("↓ \(Format.short(c.rx))").font(.caption).foregroundStyle(.secondary)
                        Text("↑ \(Format.short(c.tx))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let tcp = s.snapshot.tcp {
                Text("TCP: \(tcp.established) established" + (s.tcpRetransmitPercent.map { String(format: " · %.2f%% retransmitted", $0) } ?? ""))
                    .font(.caption).foregroundStyle((s.tcpRetransmitPercent ?? 0) > 2 ? .orange : .secondary)
                    .help("Retransmitted segments over the last poll; a few percent or more points at packet loss.")
            }
        }
        .padding(14).frame(maxWidth: .infinity).card()
    }

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { cardTitle("IP Location", "mappin.and.ellipse", .indigo); Spacer(); Text(monitor.machine.host).font(.caption).foregroundStyle(.secondary) }
            if let loc = monitor.location {
                Map(initialPosition: .region(MKCoordinateRegion(center: loc.coordinate, span: .init(latitudeDelta: 1.5, longitudeDelta: 1.5)))) {
                    Marker(monitor.machine.displayName, coordinate: loc.coordinate)
                }
                .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 8))
                Grid(alignment: .leading, verticalSpacing: 4) {
                    GridRow { Text("City").foregroundStyle(.secondary); Text("\(loc.city), \(loc.region)") }
                    GridRow { Text("Country").foregroundStyle(.secondary); Text("\(loc.flag) \(loc.country)") }
                    GridRow { Text("Organization").foregroundStyle(.secondary); Text(loc.org) }
                }.font(.caption)
            } else {
                Text("Locating…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity).card()
    }

    private func storageCard(_ s: MachineStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Storage", "internaldrive", .green)
            ForEach(s.snapshot.disks) { d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(d.filesystem).font(.caption.weight(.medium)); Spacer(); Text("\(Format.short(d.used)) / \(Format.short(d.total))").font(.caption).monospacedDigit() }
                    ProgressView(value: Double(d.used), total: Double(d.total)).tint(Double(d.used) / Double(d.total) > 0.9 ? .red : .green)
                    Text(d.mount).font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 24) {
                RateLine(icon: "arrow.down.to.line.circle", bytesPerSec: s.diskIO.rx)
                RateLine(icon: "arrow.up.to.line.circle", bytesPerSec: s.diskIO.tx)
            }
            if !s.devices.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow { Text("Device"); Text("Read"); Text("Write"); Text("IOPS"); Text("Wait") }
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    ForEach(s.devices) { d in
                        GridRow {
                            Text(d.name); Text(Format.short(Int64(d.read)) + "/s"); Text(Format.short(Int64(d.write)) + "/s")
                            Text(String(format: "%.0f", d.iops)); Text(String(format: "%.1f ms", d.awaitMs))
                        }.font(.caption).monospacedDigit()
                    }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity).card()
    }

    private func pct(_ v: Double) -> String { "%\(Int(v.rounded()))" }
    private func stat(_ title: String, _ value: String, _ color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) { if color != .primary { Circle().fill(color).frame(width: 6, height: 6) }; Text(title).font(.caption2).foregroundStyle(.secondary) }
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }
    private func legend(_ color: Color, _ value: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) { Text(value).font(.caption.weight(.semibold)); Text(label).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct GlobalViewSheet: View {
    let monitors: [MachineMonitor]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Text("Global View").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            Map {
                ForEach(monitors.filter { $0.location != nil }) { m in
                    Annotation(m.machine.displayName, coordinate: m.location!.coordinate) {
                        HStack(spacing: 6) {
                            Text(m.location!.flag)
                            Text(m.machine.displayName).font(.caption.weight(.medium)).lineLimit(1)
                            if let ms = m.latencyMs { Text("\(ms) ms").font(.caption2).foregroundStyle(.green) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
                    }
                }
            }
            Divider()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 720, height: 520)
    }
}
