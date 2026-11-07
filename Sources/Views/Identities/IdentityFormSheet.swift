import SwiftUI
import SwiftData

struct IdentityFormSheet: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SSHKey.name) private var keys: [SSHKey]
    var identity: Identity?
    var onSaved: ((Identity) -> Void)? = nil

    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var sshKey: SSHKey?
    @State private var remark = Machine.defaultRemark()
    @State private var pickKey = false
    @State private var createKey = false

    private var canSave: Bool { !name.isEmpty && !username.isEmpty && (!password.isEmpty || sshKey != nil) }

    var body: some View {
        FormSheet(title: identity == nil ? "Create New Identity" : "Edit Identity", canSave: canSave, onSave: save) {
            Section("Identity Information") {
                TextField("Name", text: $name, prompt: Text("Identity Name"))
                TextField("Username", text: $username, prompt: Text("Username"))
            }
            Section {
                SecretField(label: "Password", text: $password)
                LabeledContent("SSH Key") {
                    ChipButton(title: sshKey?.name ?? "Select SSH Key", icon: "key") { pickKey = true }
                }
            } header: { Text("Authentication") } footer: {
                Text("Password and SSH Key are optional; however, at least one is required.\nIf both are provided, SwiftPulse will attempt to use the SSH Key first. If that fails, it will then use the Password.")
            }
            Section("Remark") { TextField("Identity Remark", text: $remark, axis: .vertical) }
        }
        .task { await load() }
        .sheet(isPresented: $pickKey) {
            PickerSheet(title: "Select SSH Key", items: keys, noneTitle: "No SSH Key", onCreate: { pickKey = false; createKey = true },
                        onSelect: { sshKey = $0 },
                        row: { ResourceCard(icon: "key", title: $0.name, subtitle: $0.keyType.title) },
                        matches: { $0.name.localizedCaseInsensitiveContains($1) })
        }
        .sheet(isPresented: $createKey) { SSHKeyGenerateSheet { sshKey = $0 } }
    }

    private func load() async {
        guard let identity else { return }
        name = identity.name; username = identity.username; sshKey = identity.sshKey; remark = identity.remark
        if identity.hasPassword, await LocalAuth.authorize(reason: "edit the password of “\(identity.name)”") {
            password = KeychainService.get(identity.passwordKey) ?? ""
        }
    }

    private func save() {
        let target = identity ?? Identity()
        target.name = name; target.username = username; target.sshKey = sshKey; target.remark = remark
        target.hasPassword = !password.isEmpty
        KeychainService.set(password.isEmpty ? nil : password, for: target.passwordKey)
        if identity == nil { context.insert(target) }
        onSaved?(target)
    }
}

struct IdentityDetailView: View {
    let identity: Identity
    @State private var edit = false

    var body: some View {
        Page(title: "Identity Detail") {
            Form {
                Section("Identity Information") {
                    DetailRow(label: "Name", value: identity.name)
                    DetailRow(label: "Remark", value: identity.remark)
                }
                Section("Authentication") {
                    DetailRow(label: "Username", value: identity.username)
                    DetailRow(label: "Password", value: identity.hasPassword ? "••••••••" : "Not set")
                    DetailRow(label: "SSH Key", value: identity.sshKey?.name ?? "None")
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).frame(minHeight: 320)
        }
        .toolbar { ToolbarItem { Button("Edit") { edit = true } } }
        .sheet(isPresented: $edit) { IdentityFormSheet(identity: identity) }
    }
}
