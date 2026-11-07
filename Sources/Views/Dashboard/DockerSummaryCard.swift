import SwiftUI

/// The status page's Docker card: the engine, its containers and what they use. The status page wraps it in a link
/// to the machine's Docker page.
struct DockerSummaryCard: View {
    let session: DockerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Docker", systemImage: "shippingbox").font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                Spacer()
                if session.isReady {
                    Text("v\(session.inventory.engine.version)").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
        .help("Open the Docker page")
    }

    @ViewBuilder private var content: some View {
        if let error = session.error {
            Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        } else if !session.isReady {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to Docker…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            let inventory = session.inventory
            let running = inventory.containers.filter(\.isRunning)
            HStack(alignment: .top, spacing: 24) {
                figure("Containers", "\(running.count) / \(inventory.containers.count)", caption: "running")
                figure("Images", "\(inventory.images.count)")
                figure("CPU", String(format: "%%%.1f", inventory.containerCPU))
                figure("Memory", Format.short(inventory.containerMemory))
            }
            let busiest = running
                .compactMap { container in inventory.stats(for: container).map { (container.name, $0.memoryUsed) } }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
            if !busiest.isEmpty {
                Divider()
                ForEach(Array(busiest), id: \.0) { name, memory in
                    HStack {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(verbatim: name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(Format.short(memory)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func figure(_ title: String, _ value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
