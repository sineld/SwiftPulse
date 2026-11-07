import SwiftUI

struct DockerOverviewTab: View {
    let session: DockerSession

    private var inventory: DockerInventory { session.inventory }
    private var dangling: Int { inventory.images.filter(\.isDangling).count }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                DockerEngineCard(engine: inventory.engine, disk: inventory.disk, dangling: dangling)
                DockerStateCard(engine: inventory.engine)
                DockerLiveResourcesCard(inventory: inventory)
                DockerDiskCard(disk: inventory.disk)
                DockerEngineDetailsCard(engine: inventory.engine)
            }
            .padding(Theme.pagePadding)
        }
    }
}

/// Engine banner: whale, version, connection state, socket chip and the four headline tiles.
struct DockerEngineCard: View {
    let engine: DockerEngine
    let disk: DockerDisk
    let dangling: Int

    var body: some View {
        VStack(spacing: 14) {
            header
            Divider()
            HStack(spacing: 12) {
                DockerStatTile(icon: "shippingbox", tint: .accentColor, title: "Containers",
                               value: "\(engine.containers)",
                               detail: "\(engine.paused) paused · \(engine.stopped) stopped")
                DockerStatTile(icon: "play.circle", tint: .green, title: "Running",
                               value: "\(engine.running)", detail: "active containers")
                DockerStatTile(icon: "opticaldiscdrive", tint: .blue, title: "Images",
                               value: "\(engine.images)", detail: "\(dangling) dangling")
                DockerStatTile(icon: "arrow.3.trianglepath", tint: .orange, title: "Reclaimable",
                               value: Format.precise(disk.reclaimable),
                               detail: "%\(Int(disk.reclaimablePercent.rounded())) of Docker data")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
                .frame(width: 54, height: 54)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Docker Engine").font(.headline)
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                    Text("Connected").font(.caption).foregroundStyle(.green)
                }
                Text("v\(engine.version)").font(.title2.weight(.semibold))
                Text(engine.systemLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !engine.socket.isEmpty {
                Label("Socket: \(engine.socket)", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Total containers with a running/paused/stopped/other breakdown.
struct DockerStateCard: View {
    let engine: DockerEngine

    var body: some View {
        DockerCard(title: "Container State", icon: "shippingbox", tint: .green) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(engine.containers)").font(.system(size: 34, weight: .semibold)).monospacedDigit()
                Text("total").font(.caption).foregroundStyle(.secondary)
            }
            DockerSegmentBar(segments: segments)
            HStack(spacing: 12) {
                DockerLegend(color: .green, title: "Running", value: "\(engine.running)")
                DockerLegend(color: .orange, title: "Paused", value: "\(engine.paused)")
                DockerLegend(color: .secondary, title: "Stopped", value: "\(engine.stopped)")
                DockerLegend(color: .yellow, title: "Other", value: "\(engine.other)")
            }
        }
    }

    private var segments: [DockerSegmentBar.Segment] {
        [.init(color: .green, value: Double(engine.running)),
         .init(color: .orange, value: Double(engine.paused)),
         .init(color: .secondary, value: Double(engine.stopped)),
         .init(color: .yellow, value: Double(engine.other))]
    }
}

/// Aggregate container CPU/memory plus the top consumers.
struct DockerLiveResourcesCard: View {
    let inventory: DockerInventory

    var body: some View {
        DockerCard(title: "Live Resources", icon: "waveform.path.ecg", tint: .teal,
                   trailing: "\(inventory.liveStats.count) live") {
            HStack(spacing: 12) {
                panel(title: "Container CPU",
                      value: String(format: "%%%.1f", inventory.containerCPU),
                      fraction: inventory.containerCPU / 100,
                      detail: "Across \(inventory.liveStats.count) containers · \(inventory.engine.cpus) CPUs",
                      tint: .blue)
                panel(title: "Container Memory",
                      value: Format.precise(inventory.containerMemory),
                      fraction: memoryFraction,
                      detail: "of \(Format.precise(inventory.engine.memory)) host memory",
                      tint: .purple)
            }
            Divider()
            Text("Top Consumers").font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 20) {
                consumers(title: "CPU", icon: "cpu", tint: .blue, rows: cpuRows)
                consumers(title: "Memory", icon: "memorychip", tint: .purple, rows: memoryRows)
            }
        }
    }

    private var memoryFraction: Double {
        inventory.engine.memory > 0 ? Double(inventory.containerMemory) / Double(inventory.engine.memory) : 0
    }

    private var cpuRows: [(String, String, Double)] {
        let top = inventory.liveStats.sorted { $0.cpu > $1.cpu }.prefix(5)
        let peak = max(top.first?.cpu ?? 1, 0.0001)
        return top.map { ($0.name, String(format: "%%%.1f", $0.cpu), $0.cpu / peak) }
    }

    private var memoryRows: [(String, String, Double)] {
        let top = inventory.liveStats.sorted { $0.memoryUsed > $1.memoryUsed }.prefix(5)
        let peak = Double(max(top.first?.memoryUsed ?? 1, 1))
        return top.map { ($0.name, Format.precise($0.memoryUsed), Double($0.memoryUsed) / peak) }
    }

    private func panel(title: String, value: String, fraction: Double, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
            ProgressView(value: min(max(fraction, 0), 1)).tint(tint)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func consumers(title: String, icon: String, tint: Color, rows: [(String, String, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(tint)
            if rows.isEmpty {
                Text("No running containers").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                DockerConsumerRow(name: row.0, value: row.1, fraction: row.2, tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `docker system df` as a stacked bar plus the reclaimable line.
struct DockerDiskCard: View {
    let disk: DockerDisk

    var body: some View {
        DockerCard(title: "Disk Usage", icon: "internaldrive", tint: .green, trailing: "Docker data") {
            Text(Format.precise(disk.total)).font(.system(size: 32, weight: .semibold)).monospacedDigit()
            DockerSegmentBar(segments: segments)
            HStack(spacing: 12) {
                DockerLegend(color: .blue, title: "Images", value: Format.precise(disk.images.size))
                DockerLegend(color: .green, title: "Containers", value: Format.precise(disk.containers.size))
                DockerLegend(color: .purple, title: "Volumes", value: Format.precise(disk.volumes.size))
                DockerLegend(color: .cyan, title: "Build Cache", value: Format.precise(disk.buildCache.size))
            }
            Divider()
            HStack {
                Text("Reclaimable").font(.callout)
                Spacer()
                Text(Format.precise(disk.reclaimable)).font(.callout.weight(.medium)).foregroundStyle(.orange).monospacedDigit()
            }
            ProgressView(value: min(disk.reclaimablePercent / 100, 1)).tint(.orange)
        }
    }

    private var segments: [DockerSegmentBar.Segment] {
        [.init(color: .blue, value: Double(disk.images.size)),
         .init(color: .green, value: Double(disk.containers.size)),
         .init(color: .purple, value: Double(disk.volumes.size)),
         .init(color: .cyan, value: Double(disk.buildCache.size))]
    }
}

struct DockerEngineDetailsCard: View {
    let engine: DockerEngine

    var body: some View {
        DockerCard(title: "Engine Details", icon: "shippingbox.fill", tint: .indigo) {
            DockerRow(label: "Version", value: engine.version)
            DockerRow(label: "API Version", value: engine.apiVersion)
            DockerRow(label: "System", value: engine.systemLine)
            DockerRow(label: "Kernel", value: engine.kernel)
            DockerRow(label: "Storage Driver", value: engine.storageDriver)
            DockerRow(label: "Logging Driver", value: engine.loggingDriver)
            DockerRow(label: "Cgroup", value: engine.cgroupLine)
            DockerRow(label: "Resources", value: engine.resourceLine)
            if !engine.hostname.isEmpty { DockerRow(label: "Host", value: engine.hostname) }
        }
    }
}
