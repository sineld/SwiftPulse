import SwiftUI
import AppKit

/// Every process on a machine, the 100 busiest by CPU with their full command lines, refreshed every 3 s while
/// open (the dashboard's own poll keeps only the top few names). Sortable, searchable, and processes can be
/// stopped after a confirmation.
struct ProcessesSheet: View {
    struct Row: Identifiable, Equatable {
        var id: Int { pid }
        let pid: Int, user: String, cpu: Double, mem: Double, rssBytes: Int64, command: String
    }

    let monitor: MachineMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var error: String?
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\Row.cpu, order: .reverse)]
    @State private var selection: Row.ID?
    @State private var pendingKill: DeleteRequest?
    @State private var message: String?

    static let command = "ps -eo pid=,user=,pcpu=,pmem=,rss=,args= --sort=-pcpu 2>&1 | head -n 100"

    /// `ps` lines: pid, user, %CPU, %MEM, RSS (KiB), then the command line with its spaces.
    nonisolated static func parse(_ output: String) -> [Row] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
            guard f.count == 6, let pid = Int(f[0]), let cpu = Double(f[2]), let mem = Double(f[3]), let rss = Int64(f[4]) else { return nil }
            return Row(pid: pid, user: f[1], cpu: cpu, mem: mem, rssBytes: rss * 1024, command: f[5])
        }
    }

    private var shown: [Row] {
        let filtered = query.isEmpty ? rows : rows.filter {
            $0.command.localizedCaseInsensitiveContains(query) || $0.user.localizedCaseInsensitiveContains(query) || String($0.pid) == query
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Processes on \(monitor.machine.displayName)").font(.headline)
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 220).findShortcut(textField: true)
            }.padding(14)
            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit() }.width(60)
                TableColumn("User", value: \.user).width(90)
                TableColumn("CPU %", value: \.cpu) { Text(String(format: "%.1f", $0.cpu)).monospacedDigit() }.width(60)
                TableColumn("Mem %", value: \.mem) { Text(String(format: "%.1f", $0.mem)).monospacedDigit() }.width(60)
                TableColumn("RSS", value: \.rssBytes) { Text(Format.short($0.rssBytes)).monospacedDigit() }.width(70)
                TableColumn("Command", value: \.command) { Text($0.command).lineLimit(1).help($0.command) }
            }
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                if let pid = ids.first, let row = rows.first(where: { $0.pid == pid }) {
                    Button("Copy PID") { copy(String(pid)) }
                    Button("Copy Command") { copy(row.command) }
                    Divider()
                    Button("Terminate", role: .destructive) { confirmKill(row, signal: "TERM") }
                    Button("Force Kill", role: .destructive) { confirmKill(row, signal: "KILL") }
                }
            }
            Divider()
            HStack {
                if let text = error ?? message {
                    Text(text).font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red).lineLimit(2)
                }
                Spacer()
                Text("\(rows.count) processes").font(.caption).foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .deleteConfirmation($pendingKill)
    }

    private func load() async {
        do {
            let output = try await monitor.run(Self.command)
            let parsed = Self.parse(output)
            if parsed.isEmpty, !output.isEmpty {
                error = "ps on this machine doesn't support the needed options: \(output.prefix(120))"
            } else {
                rows = parsed
                error = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func confirmKill(_ row: Row, signal: String) {
        let force = signal == "KILL"
        pendingKill = .ask(title: force ? "Force Kill Process" : "Terminate Process",
                           message: "Send SIG\(signal) to \(row.pid) (\(row.user)): \(row.command.prefix(160))? "
                               + (force ? "It is killed at once, without a chance to clean up." : "It is asked to exit.")
                               + " If the SSH user may not signal it, sudo -n is tried.",
                           confirmTitle: force ? "Force Kill" : "Terminate") {
            Task { await kill(row.pid, signal: signal) }
        }
    }

    private func kill(_ pid: Int, signal: String) async {
        do {
            let output = try await monitor.run("kill -s \(signal) \(pid) 2>&1 || sudo -n kill -s \(signal) \(pid) 2>&1; echo \"[exit $?]\"")
            let failed = !output.contains("[exit 0]")
            message = failed ? nil : "Sent SIG\(signal) to \(pid)."
            error = failed ? output.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) : nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
