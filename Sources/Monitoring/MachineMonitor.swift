import Foundation
import SwiftData
import AppKit
import Citadel
import NIOCore

/// Live monitor for one machine: keeps an SSH client, polls metrics at the configured interval, measures latency.
@Observable @MainActor
final class MachineMonitor: Identifiable {
    enum State: Equatable { case idle, connecting, online, offline(String) }

    let id: UUID
    let machine: Machine
    private(set) var state: State = .idle
    private(set) var status: MachineStatus?
    private(set) var latencyMs: Int?
    private(set) var location: IPLocation?
    var isOnline: Bool { state == .online }

    private let container: ModelContainer
    private var client: SSHClient?
    private var task: Task<Void, Never>?
    private var lastLatencyCheck = Date.distantPast
    /// Failed polls in a row; 0 once one works.
    private var failures = 0
    /// The last poll lost a connection that worked: reconnect at once rather than wait out the interval.
    private var quickRetry = false
    /// When an agent last asked for this machine's metrics; polling goes on for a minute after, even unseen.
    private var lastDemand = Date.distantPast
    /// Views showing this machine's processes. The poll includes `ps` only while there is one (or an agent asked).
    var processViewers = 0 {
        didSet { if processViewers > 0, status?.snapshot.processes.isEmpty ?? false, isOnline { refresh() } }
    }
    private var wantsProcesses: Bool { processViewers > 0 || Date().timeIntervalSince(lastDemand) < 60 }

    init(machine: Machine, container: ModelContainer) {
        self.id = machine.id
        self.machine = machine
        self.container = container
    }

    var refreshInterval: TimeInterval { TimeInterval(UserDefaults.standard.object(forKey: "dashboardRefreshInterval") as? Int ?? 5) }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                if Self.shouldPoll(visible: Self.appVisible, lastDemand: self.lastDemand) { await self.poll() }
                try? await Task.sleep(for: .seconds(Self.delay(failures: self.failures, quickRetry: self.quickRetry,
                                                               interval: self.refreshInterval)))
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        let c = client; client = nil
        Task { try? await c?.close() }
        state = .idle
    }

    func refresh() { Task { await poll() } }

    /// An agent wants this machine's readings: keep polling it for a while, and poll now if what we have is stale.
    /// Without any reading yet the loop's next turn polls (it sees the demand), so this never opens a second connection.
    func demand() {
        lastDemand = Date()
        // Stale, or polled while nobody wanted processes (agents get the top ones).
        if let status, state == .online,
           Date().timeIntervalSince(status.snapshot.takenAt) > 2 * refreshInterval || status.snapshot.processes.isEmpty { refresh() }
    }

    /// Whether any SwiftPulse window is on screen. Nobody looks at metrics otherwise, so the 20-odd connections rest.
    static var appVisible: Bool { NSApp?.occlusionState.contains(.visible) ?? true }

    nonisolated static func shouldPoll(visible: Bool, lastDemand: Date, now: Date = Date()) -> Bool {
        visible || now.timeIntervalSince(lastDemand) < 60
    }

    /// The wait before the next poll: the refresh interval while it works; 1 s to reconnect a connection that just
    /// dropped (a Mac waking from sleep); then 5 s more per failure in a row, up to 30 s.
    nonisolated static func delay(failures: Int, quickRetry: Bool, interval: TimeInterval) -> TimeInterval {
        if quickRetry { return 1 }
        return failures == 0 ? interval : min(5 * Double(failures), 30)
    }

    private func poll() async {
        do {
            if client == nil || client?.isConnected == false {
                state = .connecting
                let spec = try ConnectionSpec.make(for: machine, in: ModelContext(container))
                client = try await SSHService.connect(spec, container: container)
            }
            guard let client else { return }
            if Date().timeIntervalSince(lastLatencyCheck) > 30 {
                let t0 = Date()
                _ = try await client.executeCommand("true", maxResponseSize: 64)
                latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
                lastLatencyCheck = Date()
            }
            let out = try await client.executeCommand(MetricsCollector.script(processes: wantsProcesses), maxResponseSize: 4 * 1024 * 1024, mergeStreams: false, inShell: false)
            let snap = MetricsCollector.parse(String(buffer: out))
            status = MachineStatus(current: snap, previous: status)
            state = .online
            failures = 0
            quickRetry = false
            if location == nil { Task { location = await IPLocation.lookup(host: machine.host) } }
        } catch {
            // A connection that worked and dropped once gets a quick reconnect with its readings kept; only a
            // second failure in a row shows the machine as offline.
            let dropped = state == .online && failures == 0
            failures += 1
            quickRetry = dropped
            state = dropped ? .connecting : .offline(error.localizedDescription)
            let c = client; client = nil
            Task { try? await c?.close() }
        }
    }

    /// Closes the cached SSH client; the next poll or `run` reconnects (fresh login, fresh groups).
    func dropConnection() async {
        let c = client; client = nil
        try? await c?.close()
    }

    /// Shares the monitor's client for one-off commands (Docker, snippets).
    func run(_ command: String, maxBytes: Int = 1 << 20) async throws -> String {
        if client == nil || client?.isConnected == false {
            let spec = try ConnectionSpec.make(for: machine, in: ModelContext(container))
            client = try await SSHService.connect(spec, container: container)
        }
        let out = try await client!.executeCommand(command, maxResponseSize: maxBytes, mergeStreams: true, inShell: false)
        return String(buffer: out)
    }
}

/// Registry of monitors for machines shown on the dashboard.
@Observable @MainActor
final class DashboardStore {
    private(set) var monitors: [UUID: MachineMonitor] = [:]
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    func sync(with machines: [Machine]) {
        let wanted = Set(machines.filter(\.showInDashboard).map(\.id))
        for (id, monitor) in monitors where !wanted.contains(id) { monitor.stop(); monitors[id] = nil }
        for machine in machines where wanted.contains(machine.id) {
            let monitor = monitors[machine.id] ?? MachineMonitor(machine: machine, container: container)
            monitors[machine.id] = monitor
            monitor.start() // idempotent; also starts monitors created early by cards
        }
    }

    func monitor(for machine: Machine) -> MachineMonitor {
        if let m = monitors[machine.id] { return m }
        let m = MachineMonitor(machine: machine, container: container)
        monitors[machine.id] = m
        return m
    }

    func refreshAll(failedOnly: Bool = false) {
        for m in monitors.values where !failedOnly || !m.isOnline { m.refresh() }
    }

    var onlineCount: Int { monitors.values.filter(\.isOnline).count }
    var offlineCount: Int { monitors.values.filter { if case .offline = $0.state { true } else { false } }.count }
}
