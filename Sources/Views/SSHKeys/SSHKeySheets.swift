import SwiftUI
import SwiftData

struct SSHKeyGenerateSheet: View {
    @Environment(\.modelContext) private var context
    var onSaved: ((SSHKey) -> Void)? = nil
    @State private var name = ""
    @State private var type: SSHKeyType = .ed25519
    @State private var remark = Machine.defaultRemark()
    @State private var error: String?

    var body: some View {
        FormSheet(title: "Generate New SSH Key", saveTitle: "Generate", canSave: !name.isEmpty, onSave: generate) {
            Section("Key Information") {
                TextField("Name", text: $name, prompt: Text("Name"))
                Picker("Key Type", selection: $type) {
                    ForEach(SSHKeyType.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Remark") { TextField("Key Remark", text: $remark, axis: .vertical) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
    }

    private func generate() {
        do {
            let pair = try SSHKeyGenerator.generate(type, comment: name)
            let key = SSHKey(name: name, keyType: type, publicKey: pair.publicKey)
            key.remark = remark
            KeychainService.set(pair.privateKey, for: key.privateKeyKey)
            context.insert(key)
            onSaved?(key)
        } catch { self.error = error.localizedDescription }
    }
}

/// Import from pasteboard text or a file; accepts a private key (OpenSSH/PEM) and optional public key.
/// With `key` it edits that key; an empty private key field keeps the stored one.
struct SSHKeyImportSheet: View {
    @Environment(\.modelContext) private var context
    var key: SSHKey?
    var initialPrivate = ""
    @State private var name = ""
    @State private var privateKey = ""
    @State private var publicKey = ""
    @State private var passphrase = ""
    @State private var remark = Machine.defaultRemark()

    var body: some View {
        FormSheet(title: key == nil ? "Import SSH Key" : "Edit SSH Key", saveTitle: key == nil ? "Import" : "Save",
                  canSave: !name.isEmpty && (key != nil || !privateKey.isEmpty) && keyError == nil, onSave: save) {
            Section("Key Information") { TextField("Name", text: $name, prompt: Text("Name")) }
            Section {
                TextEditor(text: $privateKey).font(.system(.caption, design: .monospaced)).frame(minHeight: 140)
                if let keyError { Text(keyError).foregroundStyle(.red) }
                else if key != nil, privateKey.isEmpty { Text("Leave empty to keep the stored private key.").foregroundStyle(.secondary) }
                Button("Choose File…") { pickKeyFile() }
            } header: { Text("Private Key") }
            Section("Public Key (optional)") {
                TextEditor(text: $publicKey).font(.system(.caption, design: .monospaced)).frame(minHeight: 60)
            }
            Section("Passphrase (if the key is encrypted)") { SecretField(label: "Passphrase", text: $passphrase) }
            Section("Remark") { TextField("Key Remark", text: $remark, axis: .vertical) }
        }
        .onAppear {
            guard let key else { privateKey = initialPrivate; return }
            name = key.name; publicKey = key.publicKey; remark = key.remark
            passphrase = KeychainService.get(key.passphraseKey) ?? ""
        }
    }

    private var keyError: String? {
        guard !privateKey.isEmpty else { return nil }
        do { try OpenSSHPrivateKey.validate(privateKey); return nil } catch { return error.localizedDescription }
    }

    /// Reads a private key file and, when it sits next to one, its `.pub` companion (picking the `.pub` loads its private key).
    private func pickKeyFile() {
        let sshFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        guard let picked = FilePanel.openFile(title: "Import Private Key",
                                              message: "Pick a private key file, for example ~/.ssh/id_ed25519.",
                                              directory: sshFolder, prompt: "Import").first else { return }
        let url = picked.pathExtension == "pub" ? picked.deletingPathExtension() : picked
        privateKey = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if name.isEmpty { name = url.lastPathComponent }
        publicKey = (try? String(contentsOf: url.appendingPathExtension("pub"), encoding: .utf8)) ?? publicKey
    }

    private func save() {
        if publicKey.isEmpty, PKCS1Converter.isPKCS1(privateKey), let derived = try? PKCS1Converter.publicKeyLine(privateKey, comment: name) {
            publicKey = derived
        }
        let target = key ?? SSHKey()
        target.name = name
        target.keyType = SSHKeyGenerator.type(fromPublicKey: publicKey) ?? guessType(privateKey) ?? target.keyType
        target.publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        target.remark = remark
        target.hasPassphrase = !passphrase.isEmpty
        if !privateKey.isEmpty { KeychainService.set(privateKey, for: target.privateKeyKey) }
        KeychainService.set(passphrase.isEmpty ? nil : passphrase, for: target.passphraseKey)
        if key == nil { context.insert(target) }
    }

    private func guessType(_ pem: String) -> SSHKeyType? {
        if pem.contains("RSA PRIVATE KEY") { return .rsa }
        if pem.contains("EC PRIVATE KEY") { return .ecdsaP256 }
        return nil
    }
}

struct SSHKeyDetailView: View {
    let key: SSHKey
    @State private var showPrivate = false
    @State private var edit = false
    @State private var exportTo = false
    @State private var exportResult: String?
    @Query(sort: \Machine.name) private var machines: [Machine]
    @Environment(DashboardStore.self) private var dashboard

    var body: some View {
        Page(title: "Key Detail") {
            Form {
                Section("Key Information") {
                    DetailRow(label: "Name", value: key.name)
                    DetailRow(label: "Type", value: key.publicKey.isEmpty ? "Unknown" : key.keyType.title)
                    DetailRow(label: "Fingerprint", value: SSHKeyGenerator.fingerprint(key.publicKey))
                    Button("Export Public Key to Server") { exportTo = true }.disabled(key.publicKey.isEmpty)
                    if let exportResult { Text(exportResult).font(.caption).foregroundStyle(exportResult.hasPrefix("Added") ? .green : .red) }
                }
                Section("Public Key") {
                    Text(key.publicKey.isEmpty ? "Not available" : key.publicKey)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Copy Public Key", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key.publicKey, forType: .string)
                    }
                }
                Section("Private Key") {
                    if showPrivate {
                        Text(KeychainService.get(key.privateKeyKey) ?? "Missing from Keychain")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Button(showPrivate ? "Hide Private Key" : "Show Private Key") {
                        if showPrivate { showPrivate = false }
                        else { Task { showPrivate = await LocalAuth.authorize(reason: "reveal the private key “\(key.name)”") } }
                    }
                }
                Section("Remark") { Text(key.remark) }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).frame(minHeight: 480)
        }
        .sheet(isPresented: $exportTo) {
            PickerSheet(title: "Export Public Key to", items: machines, onSelect: { if let m = $0 { export(to: m) } },
                        row: { ResourceCard(icon: "server.rack", title: $0.displayName, subtitle: $0.host) },
                        matches: { $0.displayName.localizedCaseInsensitiveContains($1) })
        }
        .toolbar { ToolbarItem { Button("Edit") { edit = true } } }
        .sheet(isPresented: $edit) { SSHKeyImportSheet(key: key) }
    }

    /// Appends the public key to ~/.ssh/authorized_keys on the machine (idempotent).
    private func export(to machine: Machine) {
        let line = key.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "'", with: "")
        let script = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && (grep -qxF '\(line)' ~/.ssh/authorized_keys || echo '\(line)' >> ~/.ssh/authorized_keys) && echo OK"
        Task {
            do {
                let out = try await dashboard.monitor(for: machine).run(script)
                exportResult = out.contains("OK") ? "Added to \(machine.displayName)" : out
            } catch { exportResult = error.localizedDescription }
        }
    }
}
