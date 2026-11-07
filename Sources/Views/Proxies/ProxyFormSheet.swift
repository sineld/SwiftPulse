import SwiftUI
import SwiftData

struct ProxyFormSheet: View {
    @Environment(\.modelContext) private var context
    var proxy: Proxy?
    var onSaved: ((Proxy) -> Void)? = nil
    @State private var name = ""
    @State private var host = ""
    @State private var port = 1080
    @State private var kind: ProxyKind = .socks5
    @State private var auth: ProxyAuth = .none
    @State private var username = ""
    @State private var password = ""
    @State private var remark = Machine.defaultRemark()

    var body: some View {
        FormSheet(title: proxy == nil ? "Create New Proxy" : "Edit Proxy", canSave: !name.isEmpty && !host.isEmpty, onSave: save) {
            Section("Proxy Information") {
                TextField("Name", text: $name, prompt: Text("Name"))
                TextField("Host", text: $host, prompt: Text("IP or Hostname"))
                TextField("Port", value: $port, format: .number)
                Picker("Type", selection: $kind) { ForEach(ProxyKind.allCases) { Text($0.title).tag($0) } }
            }
            Section("Authentication") {
                Picker("Authentication", selection: $auth) { ForEach(ProxyAuth.allCases) { Text($0.title).tag($0) } }
                if auth == .usernamePassword {
                    TextField("Username", text: $username, prompt: Text("Username"))
                    SecretField(label: "Password", text: $password)
                }
            }
            Section("Remark") { TextField("Proxy Remark", text: $remark, axis: .vertical) }
        }
        .onAppear {
            guard let proxy else { return }
            name = proxy.name; host = proxy.host; port = proxy.port; kind = proxy.kind; auth = proxy.auth
            username = proxy.username; remark = proxy.remark
            password = KeychainService.get(proxy.passwordKey) ?? ""
        }
    }

    private func save() {
        let target = proxy ?? Proxy()
        target.name = name; target.host = host; target.port = port; target.kind = kind; target.auth = auth
        target.username = auth == .usernamePassword ? username : ""; target.remark = remark
        KeychainService.set(auth == .usernamePassword && !password.isEmpty ? password : nil, for: target.passwordKey)
        if proxy == nil { context.insert(target) }
        onSaved?(target)
    }
}
