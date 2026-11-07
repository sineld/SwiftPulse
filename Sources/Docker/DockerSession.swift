import Foundation
import SwiftData

/// Docker management for one machine, over the machine's shared SSH connection.
///
/// Every command runs through one shell wrapper chosen at detection time (plain, `sg docker`, or passwordless
/// `sudo`), and scripts travel base64-encoded so their own quotes never need escaping.
@Observable @MainActor
final class DockerSession: Identifiable {
    enum Step: Int, CaseIterable {
        case connect, detect, load, ready
        var title: String { ["Connect", "Detect Engine", "Load Data", "Ready"][rawValue] }
    }
    enum StepState { case pending, running, done, failed }
    struct LogLine: Identifiable { let id = UUID(); let time = Date(); let category: String; let text: String }

    enum Wrapper: String, CaseIterable {
        case plain = "sh -c", group = "sg docker -c", sudo = "sudo -n sh -c"
        var label: String {
            switch self {
            case .plain: "docker"
            case .group: "sg docker"
            case .sudo: "sudo -n docker"
            }
        }
    }

    let machine: Machine
    var id: UUID { machine.id }
    private let monitor: MachineMonitor

    private(set) var steps: [Step: StepState] = [:]
    private(set) var log: [LogLine] = []
    private(set) var error: String?
    private(set) var inventory = DockerInventory()
    private(set) var wrapper: Wrapper = .plain
    private(set) var busy = false
    private(set) var lastRefresh: Date?
    private(set) var events: [DockerEvent] = []
    var isReady: Bool { steps[.ready] == .done }

    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventCursor = Date().addingTimeInterval(-300)
    private var viewers = 0

    var refreshInterval: TimeInterval { TimeInterval(UserDefaults.standard.object(forKey: "dockerRefreshInterval") as? Int ?? 5) }

    init(machine: Machine, monitor: MachineMonitor) {
        self.machine = machine
        self.monitor = monitor
        Task { await connect() }
    }

    // MARK: - connection

    func connect() async {
        steps = [:]; log = []; error = nil
        busy = true
        defer { busy = false }
        do {
            set(.connect, .running)
            add("Setup", "Setting up Docker panel with \(machine.host)")
            let who = try await run("whoami", wrapper: .plain).trimmingCharacters(in: .whitespacesAndNewlines)
            add("Transport", "Connection established as \(who)")
            set(.connect, .done)

            set(.detect, .running)
            add("Diagnostics", "Detecting Docker engine")
            wrapper = try await detectWrapper()
            add("Diagnostics", "Docker CLI reachable via `\(wrapper.label)`")
            set(.detect, .done)

            set(.load, .running)
            try await refresh()
            guard !inventory.engine.version.isEmpty else { throw DockerError.daemonDown("docker version returned nothing") }
            add("Ready", "Docker \(inventory.engine.version) · \(inventory.containers.count) containers, \(inventory.images.count) images")
            set(.load, .done)
            set(.ready, .done)
        } catch {
            self.error = error.localizedDescription
            add("Error", error.localizedDescription)
            for step in Step.allCases where steps[step] == .running { set(step, .failed) }
        }
    }

    /// Reconnects the SSH session first, so a docker-group membership granted after the last login is picked up.
    func retry() async {
        stopPolling()
        await monitor.dropConnection()
        await connect()
        if viewers > 0 { startPolling() }
    }

    private func detectWrapper() async throws -> Wrapper {
        var lastError = DockerError.permissionDenied
        for candidate in Wrapper.allCases {
            // `sg docker` is only for a user added to the group after this login, whose session lacks it yet. For
            // anyone else it asks for the group's password and waits forever, and sudo -n would never get its turn.
            if candidate == .group, !(try await isListedInDockerGroup()) {
                add("Diagnostics", "`sg docker`: skipped, the SSH user isn't in the docker group")
                continue
            }
            let output = try await run("docker version --format \"{{json .Server.Version}}\"", wrapper: candidate)
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.localizedCaseInsensitiveContains("permission denied") || text.contains("a password is required") {
                add("Diagnostics", "`\(candidate.label)`: no access to the Docker socket")
                lastError = .permissionDenied
                continue
            }
            if text.contains("not found") || text.contains("No such file") {
                add("Diagnostics", "`\(candidate.label)`: docker CLI not found")
                lastError = .notInstalled
                continue
            }
            if text.contains("Cannot connect") || text.contains("Is the docker daemon running") {
                throw DockerError.daemonDown(text)
            }
            if text.isEmpty || text.contains("error") || text.contains("Error") {
                add("Diagnostics", "`\(candidate.label)`: \(text.prefix(120))")
                continue
            }
            return candidate
        }
        throw lastError
    }

    /// Whether /etc/group lists the SSH user in `docker`, which also covers a membership granted after login.
    private func isListedInDockerGroup() async throws -> Bool {
        let script = #"getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qx "$(id -un)" && echo member"#
        return try await run(script, wrapper: .plain).contains("member")
    }

    // MARK: - polling

    /// Reference-counted so several views (tabs, detail pages) can keep the same session live.
    func addViewer() {
        viewers += 1
        if viewers == 1 { startPolling() }
    }

    func removeViewer() {
        viewers = max(viewers - 1, 0)
        if viewers == 0 { stopPolling(); stopEvents() }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.isReady { try? await self.refresh() }
                try? await Task.sleep(for: .seconds(self.refreshInterval))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async throws {
        let output = try await run(DockerInventory.script)
        inventory = DockerInventory.parse(output)
        lastRefresh = .now
    }

    func refreshNow() {
        Task {
            busy = true
            defer { busy = false }
            do { try await refresh() } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: - events

    func startEvents() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollEvents()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
    }

    private func pollEvents() async {
        let since = Int(eventCursor.timeIntervalSince1970)
        let until = Int(Date().timeIntervalSince1970)
        guard until > since else { return }
        let command = "docker events --since \(since) --until \(until) --format \"{{json .}}\""
        guard let output = try? await run(command) else { return }
        let batch = DockerInventory.parseEvents(output)
        eventCursor = Date(timeIntervalSince1970: Double(until))
        guard !batch.isEmpty else { return }
        events.append(contentsOf: batch)
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }

    func clearEvents() { events.removeAll() }

    // MARK: - actions

    func container(_ action: String, _ item: DockerContainer) async {
        await perform("docker \(action) \(item.id)", "\(action) \(item.name)")
    }
    func removeImage(_ item: DockerImage, force: Bool = false) async {
        await perform("docker rmi \(force ? "-f " : "")\(item.id)", "remove image \(item.reference)")
    }
    func removeVolume(_ item: DockerVolume) async {
        await perform("docker volume rm \(item.name)", "remove volume \(item.name)")
    }
    func removeNetwork(_ item: DockerNetwork) async {
        await perform("docker network rm \(item.id)", "remove network \(item.name)")
    }
    func compose(_ action: String, _ project: DockerCompose) async {
        let files = project.configFileList.map { "-f \($0)" }.joined(separator: " ")
        await perform("docker compose -p \(project.name) \(files) \(action)", "compose \(action) \(project.name)")
    }
    func prune(_ target: String = "system") async {
        await perform("docker \(target) prune -f", "\(target) prune")
    }
    func pull(_ reference: String) async -> String {
        busy = true
        defer { busy = false }
        let output = (try? await run("docker pull \(reference)")) ?? "pull failed"
        add("Action", "pull \(reference)")
        try? await refresh()
        return output
    }
    /// What to type into a terminal on the machine for an interactive shell in the container: bash when it has
    /// one, sh otherwise, through the same docker / sg docker / sudo -n route the panel found.
    func shellCommand(for item: DockerContainer) -> String {
        let exec = "docker exec -it \(item.id) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
        switch wrapper {
        case .plain: return exec
        case .group: return "sg docker -c \"\(exec)\""
        case .sudo: return "sudo -n " + exec
        }
    }

    func logs(_ item: DockerContainer, lines: Int = 300) async -> String {
        (try? await run("docker logs --tail \(lines) --timestamps \(item.id) 2>&1")) ?? ""
    }
    func inspect(_ id: String) async -> String {
        (try? await run("docker inspect \(id)")) ?? ""
    }

    private func perform(_ command: String, _ label: String) async {
        busy = true
        defer { busy = false }
        do {
            let output = try await run(command)
            let tail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
            add("Action", tail.isEmpty ? label : "\(label): \(tail)")
            try await refresh()
        } catch {
            self.error = error.localizedDescription
            add("Error", error.localizedDescription)
        }
    }

    // MARK: - transport

    /// Runs `script` through the detected wrapper. The script is base64-encoded, so quotes inside it are safe.
    private func run(_ script: String, wrapper override: Wrapper? = nil) async throws -> String {
        let payload = Data(script.utf8).base64EncodedString()
        let selected = override ?? wrapper
        // No input: nothing here is interactive, and a command that prompts (a password) fails instead of hanging.
        let command = "S=$(printf %s \(payload) | base64 -d); \(selected.rawValue) \"$S\" 2>&1 </dev/null; exit 0"
        return try await monitor.run(command, maxBytes: 8 << 20)
    }

    private func set(_ step: Step, _ state: StepState) { steps[step] = state }
    private func add(_ category: String, _ text: String) { log.append(LogLine(category: category, text: text)) }

    enum DockerError: LocalizedError {
        case permissionDenied, notInstalled, daemonDown(String)
        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Docker socket permission denied. Tried docker, sg docker and sudo -n. Add the SSH user to the docker group, allow passwordless sudo for docker, or enable rootless Docker."
            case .notInstalled:
                "Docker CLI not found on this machine."
            case .daemonDown(let message):
                "Docker daemon is not reachable: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}

@Observable @MainActor
final class DockerStore {
    // Not observed: sessions are created lazily inside view bodies, and observing the insert would
    // invalidate the view that just asked for it.
    @ObservationIgnored private var store: [UUID: DockerSession] = [:]
    var sessions: [UUID: DockerSession] { store }
    func session(for machine: Machine, dashboard: DashboardStore) -> DockerSession {
        if let existing = store[machine.id] { return existing }
        let session = DockerSession(machine: machine, monitor: dashboard.monitor(for: machine))
        store[machine.id] = session
        return session
    }
}
