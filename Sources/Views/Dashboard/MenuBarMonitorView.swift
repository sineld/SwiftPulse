import SwiftUI
import SwiftData
import AppKit

/// The menu bar monitor: every dashboard machine with its state, CPU and memory, a glance away from any app.
struct MenuBarMonitorView: View {
    @Environment(DashboardStore.self) private var dashboard
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Machine.name) private var machines: [Machine]

    private var monitors: [MachineMonitor] {
        dashboard.monitors.values.sorted { $0.machine.displayName.localizedStandardCompare($1.machine.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SwiftPulse").font(.headline)
                Spacer()
                Text("\(dashboard.onlineCount) online · \(dashboard.offlineCount) offline").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if monitors.isEmpty {
                Text("No machines on the dashboard.").foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) { ForEach(monitors) { MenuBarMachineRow(monitor: $0) } }.padding(6)
                }
                .frame(maxHeight: 420)
            }
            Divider()
            HStack {
                Button("Open SwiftPulse") { showMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 340)
        // Monitors start when the dashboard first shows; the menu may be opened before that.
        .onAppear { dashboard.sync(with: machines) }
    }

    /// Brings the main window forward, opening one when it was closed.
    private func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

private struct MenuBarMachineRow: View {
    let monitor: MachineMonitor

    private var color: Color {
        switch monitor.state {
        case .online: .green
        case .connecting: .orange
        case .offline: .red
        case .idle: .gray
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .accessibilityLabel(monitor.isOnline ? "Online" : "Not online")
            Text(monitor.machine.displayName).lineLimit(1)
            Spacer()
            if let status = monitor.status, monitor.isOnline {
                Text("CPU \(Int(status.cpu.total.rounded()))%").frame(width: 62, alignment: .trailing)
                Text("RAM \(Int(status.memPercent.rounded()))%").frame(width: 66, alignment: .trailing)
            } else if case .offline = monitor.state {
                Text("Offline").foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 6).padding(.vertical, 4)
        .help(offlineReason ?? monitor.machine.host)
    }

    private var offlineReason: String? {
        if case .offline(let why) = monitor.state { return why }
        return nil
    }
}
