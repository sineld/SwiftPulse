import SwiftUI
import SwiftData

/// Runs a snippet on one or more machines at once (a few at a time) and shows each machine's exit code and output
/// as it finishes. Unknown host keys aren't asked about here: those machines report it and are skipped.
struct SnippetRunSheet: View {
    let snippet: Snippet
    @Query(sort: \Machine.name) private var machines: [Machine]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("snippetTimeout") private var timeout = 15
    @State private var selected: Set<UUID> = []
    @State private var results: [AgentRunResult] = []
    @State private var expanded: Set<String> = []
    @State private var running = false
    @State private var pick = false

    private var chosen: [Machine] { machines.filter { selected.contains($0.id) } }
    private var selectionTitle: String {
        switch chosen.count {
        case 0: "Select Machines"
        case 1: chosen[0].displayName
        default: "\(chosen.count) Machines"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run “\(snippet.name)”").font(.headline)
                Spacer()
                ChipButton(title: selectionTitle, icon: "server.rack") { pick = true }
            }.padding(14)
            Divider()
            Group {
                if results.isEmpty {
                    Text(running ? "Running…" : "Output will appear here.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results, id: \.hostID) { result in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(result.hostID) },
                                                            set: { if $0 { expanded.insert(result.hostID) } else { expanded.remove(result.hostID) } })) {
                            output(result)
                        } label: {
                            resultLabel(result)
                        }
                    }
                }
            }
            .background(.quaternary.opacity(0.3))
            Divider()
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("\(results.count) of \(chosen.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run", systemImage: "play.fill", action: run).buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || running).keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 680, height: 500)
        .onAppear { if machines.count == 1 { selected = [machines[0].id] } }
        .sheet(isPresented: $pick) { MachineMultiPicker(machines: machines, selected: $selected) }
    }

    private func resultLabel(_ result: AgentRunResult) -> some View {
        HStack {
            Image(systemName: result.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.exitCode == 0 ? .green : .red)
                .accessibilityLabel(result.exitCode == 0 ? "Succeeded" : "Failed")
            Text(result.host).font(.body.weight(.medium))
            Spacer()
            Text(result.exitCode.map { "exit \($0)" } ?? "failed").font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(String(format: "%.1f s", result.seconds)).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func output(_ result: AgentRunResult) -> some View {
        let text = [result.error, result.output.isEmpty ? nil : result.output].compactMap { $0 }.joined(separator: "\n")
        return Text(text.isEmpty ? "No output." : (result.truncated ? "…\n" : "") + text)
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }

    private func run() {
        let targets = chosen
        guard !targets.isEmpty else { return }
        running = true
        results = []
        expanded = []
        let script = snippet.script
        let container = context.container
        Task {
            _ = await AgentRunner.run(command: script, on: targets, sudo: false, timeout: TimeInterval(timeout),
                                      concurrency: 8, container: container) { result in
                results.append(result)
                // One machine, or one that failed: show its output without a click.
                if targets.count == 1 || result.exitCode != 0 { expanded.insert(result.hostID) }
            }
            running = false
        }
    }
}

/// Picks any number of machines, with search and whole groups.
private struct MachineMultiPicker: View {
    let machines: [Machine]
    @Binding var selected: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [Machine] {
        query.isEmpty ? machines : machines.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.host.localizedCaseInsensitiveContains(query)
                || ($0.group?.name.localizedCaseInsensitiveContains(query) ?? false)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private var groups: [String] { Array(Set(machines.compactMap { $0.group?.name })).sorted() }

    private func toggle(_ ids: [UUID]) {
        if Set(ids).isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Machines").font(.headline)
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 200).findShortcut(textField: true)
            }.padding(14)
            if !groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(groups, id: \.self) { group in
                            Button(group) { toggle(machines.filter { $0.group?.name == group }.map(\.id)) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("Select or deselect every machine in \(group)")
                        }
                    }.padding(.horizontal, 14)
                }.padding(.bottom, 8)
            }
            List(shown) { machine in
                Toggle(isOn: Binding(get: { selected.contains(machine.id) },
                                     set: { if $0 { selected.insert(machine.id) } else { selected.remove(machine.id) } })) {
                    VStack(alignment: .leading) {
                        Text(machine.displayName)
                        Text(machine.host).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Divider()
            HStack {
                Button(Set(shown.map(\.id)).isSubset(of: selected) ? "Deselect All" : "Select All") { toggle(shown.map(\.id)) }
                Spacer()
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 480, height: 520)
    }
}
