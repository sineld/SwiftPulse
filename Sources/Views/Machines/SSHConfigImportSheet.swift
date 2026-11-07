import SwiftUI
import SwiftData

/// Lists the hosts in ~/.ssh/config (as `ssh -G` resolves them) and adds the chosen ones as machines.
struct SSHConfigImportSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var machines: [Machine]
    @State private var entries: [SSHConfigImport.Entry]?
    @State private var selected: Set<String> = []
    @State private var outcome: SSHConfigImport.Outcome?
    @State private var error: String?

    private func exists(_ entry: SSHConfigImport.Entry) -> Bool {
        machines.contains { $0.host == entry.hostname && $0.port == entry.port && $0.username == entry.user }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import from SSH Config").font(.headline)
                Spacer()
                Text("~/.ssh/config").font(.caption.monospaced()).foregroundStyle(.secondary)
            }.padding(14)
            Divider()
            Group {
                if let outcome {
                    result(outcome)
                } else if let entries {
                    if entries.isEmpty {
                        ContentUnavailableView("No hosts found", systemImage: "doc.text.magnifyingglass",
                                               description: Text("~/.ssh/config has no Host entries without wildcards."))
                    } else {
                        List(entries) { entry in row(entry) }
                    }
                } else {
                    ProgressView("Reading ~/.ssh/config…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                if outcome == nil {
                    Text("Private key files are copied into SwiftPulse's secret store.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                if outcome == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Import \(selected.count)") { runImport() }.buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }.padding(12)
        }
        .frame(width: 640, height: 480)
        .task {
            let loaded = await SSHConfigImport.load()
            entries = loaded
            // Git hosts (github.com and the like sign in as git) aren't shells: listed, but not ticked.
            selected = Set(loaded.filter { !exists($0) && $0.user != "git" }.map(\.alias))
        }
    }

    private func row(_ entry: SSHConfigImport.Entry) -> some View {
        let already = exists(entry)
        return Toggle(isOn: Binding(get: { selected.contains(entry.alias) },
                                    set: { if $0 { selected.insert(entry.alias) } else { selected.remove(entry.alias) } })) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.alias).font(.body.weight(.medium))
                    if already { Text("Already added").font(.caption).foregroundStyle(.secondary) }
                }
                Text("\(entry.user)@\(entry.hostname):\(entry.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
                let details = [entry.identityFile.map { "key: " + ($0 as NSString).abbreviatingWithTildeInPath },
                               entry.proxyJump.isEmpty ? nil : "via " + entry.proxyJump.joined(separator: " → ")].compactMap { $0 }
                if !details.isEmpty { Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(already)
    }

    private func result(_ outcome: SSHConfigImport.Outcome) -> some View {
        List {
            if !outcome.added.isEmpty { Section("Added") { ForEach(outcome.added, id: \.self) { Text($0) } } }
            if !outcome.skipped.isEmpty { Section("Already in SwiftPulse") { ForEach(outcome.skipped, id: \.self) { Text($0) } } }
            if !outcome.notes.isEmpty {
                Section("Check") { ForEach(outcome.notes, id: \.self) { Text($0).foregroundStyle(.orange) } }
            }
        }
    }

    private func runImport() {
        guard let entries else { return }
        do {
            outcome = try SSHConfigImport.importEntries(entries.filter { selected.contains($0.alias) }, into: context)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
