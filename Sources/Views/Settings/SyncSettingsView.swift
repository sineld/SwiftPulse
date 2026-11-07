import SwiftUI

/// Settings page for the local (folder-based) sync.
struct SyncSettingsView: View {
    @Environment(SyncService.self) private var sync
    @State private var preview: PreviewState?
    @State private var strategy: SyncVault.Strategy = .merge
    @State private var pendingDelete: DeleteRequest?

    private struct PreviewState: Identifiable {
        let id = UUID()
        let vault: SyncVault
        let envelope: VaultEnvelope
        let source: String
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(sync.folderPath.isEmpty ? "Not set" : displayPath)
                            .foregroundStyle(sync.folderPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { sync.chooseFolder() }
                        if !sync.folderPath.isEmpty {
                            Button("Reveal", systemImage: "folder") { sync.revealInFinder() }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                SecretField(label: "Passphrase", text: Bindable(sync).passphrase)
                Toggle("Export after every change", isOn: Bindable(sync).autoExport)
            } header: {
                Text("Local Sync")
            } footer: {
                Text("Machines, identities, keys, proxies, snippets, rules, trusted host keys and settings are written to **\(SyncService.Keys.fileName)** in that folder, encrypted with your passphrase. Point it at a directory your own cloud client syncs, then import it on the other Mac.")
            }

            Section("Status") {
                DetailRow(label: "Vault file", value: sync.vaultExists ? "Present" : "Not created yet")
                if let envelope = sync.remoteEnvelope() {
                    DetailRow(label: "Written by", value: envelope.device)
                    DetailRow(label: "File date", value: envelope.exportedAt.formatted(date: .abbreviated, time: .shortened))
                }
                DetailRow(label: "Last export", value: sync.lastExport?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                DetailRow(label: "Last import", value: sync.lastImport?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                if let status = sync.status { Text(status).font(.caption).foregroundStyle(.green) }
                if let error = sync.error { Text(error).font(.caption).foregroundStyle(.red) }
            }

            Section {
                HStack {
                    Button("Export Now", systemImage: "arrow.up.doc") { sync.exportNow() }
                        .disabled(!sync.isConfigured || sync.busy)
                    Button("Import from Folder", systemImage: "arrow.down.doc") { loadFromFolder() }
                        .disabled(!sync.isConfigured || !sync.vaultExists || sync.busy)
                    Button("Import File…", systemImage: "folder.badge.plus") { pickVaultFile() }
                        .disabled(sync.passphrase.isEmpty || sync.busy)
                    if sync.busy { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("Import asks what to do with the local data before it changes anything.")
            }

            Section("This Device") {
                DetailRow(label: "Device name", value: SyncVault.deviceName)
                DetailRow(label: "Data folder", value: AppPaths.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Button("Reveal Data Folder", systemImage: "folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.directory.path)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Local Sync")
        .deleteConfirmation($pendingDelete)
        .sheet(item: $preview) { state in
            SyncImportSheet(state: state.vault, envelope: state.envelope, source: state.source, strategy: $strategy) {
                guard strategy == .replace else {
                    sync.apply(state.vault, strategy: .merge)
                    return
                }
                pendingDelete = .ask(title: "Replace Local Data",
                                     message: "Every machine, group, identity, SSH key, proxy, snippet and port-forwarding rule on this Mac is deleted first, then the vault from “\(state.envelope.device)” is imported.",
                                     confirmTitle: "Replace") {
                    sync.apply(state.vault, strategy: .replace)
                }
            }
        }
    }

    private var displayPath: String {
        sync.folderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func pickVaultFile() {
        let directory = sync.folderPath.isEmpty ? nil : URL(fileURLWithPath: sync.folderPath)
        guard let url = FilePanel.openFile(title: "Import Vault",
                                           message: "Pick a SwiftPulse vault file (\(SyncService.Keys.fileName)).",
                                           directory: directory, prompt: "Import").first else { return }
        load(url, source: url.lastPathComponent)
    }

    private func loadFromFolder() {
        guard let url = sync.vaultURL else { return }
        load(url, source: SyncService.Keys.fileName)
    }

    private func load(_ url: URL, source: String) {
        do {
            let (vault, envelope) = try sync.read(from: url)
            preview = PreviewState(vault: vault, envelope: envelope, source: source)
        } catch {
            preview = nil
            sync.reportImportFailure(error)
        }
    }
}

/// Shows what a vault holds and which import strategy to use, before anything is written.
struct SyncImportSheet: View {
    let state: SyncVault
    let envelope: VaultEnvelope
    let source: String
    @Binding var strategy: SyncVault.Strategy
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import Vault").font(.headline)
                Spacer()
            }
            .padding(14)
            Divider()
            Form {
                Section("Vault") {
                    DetailRow(label: "File", value: source)
                    DetailRow(label: "Device", value: envelope.device)
                    DetailRow(label: "Exported", value: envelope.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    DetailRow(label: "App version", value: envelope.app)
                }
                Section("Contents") {
                    ForEach(state.counts.filter { $0.1 > 0 }, id: \.0) { entry in
                        DetailRow(label: entry.0, value: "\(entry.1)")
                    }
                }
                Section {
                    Picker("Strategy", selection: $strategy) {
                        ForEach(SyncVault.Strategy.allCases) { option in Text(option.title).tag(option) }
                    }
                    .pickerStyle(.segmented)
                    Text(strategy.detail).font(.caption).foregroundStyle(strategy == .replace ? .red : .secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { onImport(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
    }
}
