import SwiftUI
import SwiftData

struct PortForwardingFormSheet: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Machine.name) private var machines: [Machine]
    @Query(sort: \Proxy.name) private var proxies: [Proxy]
    var rule: PortForwardingRule?
    @State private var name = ""
    @State private var mode: ForwardingMode = .local
    @State private var machine: Machine?
    @State private var proxy: Proxy?
    @State private var localHost = "127.0.0.1"
    @State private var localPort = 0
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = 80
    @State private var autoStart = false
    @State private var remark = Machine.defaultRemark()
    @State private var pick: Pick?
    enum Pick: Identifiable { case machine, proxy; var id: Self { self } }

    var body: some View {
        FormSheet(title: rule == nil ? "Create New Port Forwarding" : "Edit Port Forwarding",
                  canSave: !name.isEmpty && machine != nil, onSave: save) {
            Section("Port Forwarding Information") {
                TextField("Name", text: $name, prompt: Text("Name"))
                Picker("Mode", selection: $mode) { ForEach(ForwardingMode.allCases) { Text($0.title).tag($0) } }
                LabeledContent("Machine") { ChipButton(title: machine?.displayName ?? "Select Machine", icon: "server.rack") { pick = .machine } }
                LabeledContent("Proxy") { ChipButton(title: proxy?.name ?? "Select Proxy", icon: "globe") { pick = .proxy } }
            }
            Section(mode == .remote ? "Remote (listens on the server)" : "Local") {
                TextField("Local Host", text: $localHost, prompt: Text("Local Host"))
                TextField("Local Port", value: $localPort, format: .number)
            }
            if mode != .dynamic {
                Section("Target") {
                    TextField("Target Host", text: $targetHost, prompt: Text("Target Host"))
                    TextField("Target Port", value: $targetPort, format: .number)
                }
            }
            Section("Preferences") { Toggle("Auto Start", isOn: $autoStart) }
            Section("Remark") { TextField("Port Forwarding Remark", text: $remark, axis: .vertical) }
        }
        .onAppear(perform: load)
        .sheet(item: $pick) { which in
            switch which {
            case .machine:
                PickerSheet(title: "Select Machine", items: machines, onSelect: { machine = $0 },
                            row: { ResourceCard(icon: "server.rack", title: $0.displayName, subtitle: $0.host) },
                            matches: { $0.displayName.localizedCaseInsensitiveContains($1) || $0.host.contains($1) })
            case .proxy:
                PickerSheet(title: "Select Proxy", items: proxies, noneTitle: "No Proxy", onSelect: { proxy = $0 },
                            row: { ResourceCard(icon: "globe", title: $0.name, subtitle: "\($0.host):\($0.port)") },
                            matches: { $0.name.localizedCaseInsensitiveContains($1) })
            }
        }
    }

    private func load() {
        guard let rule else { return }
        name = rule.name; mode = rule.mode; localHost = rule.localHost; localPort = rule.localPort
        targetHost = rule.targetHost; targetPort = rule.targetPort; autoStart = rule.autoStart; remark = rule.remark
        machine = machines.first { $0.id == rule.machineID }
        proxy = proxies.first { $0.id == rule.proxyID }
    }

    private func save() {
        let target = rule ?? PortForwardingRule()
        target.name = name; target.mode = mode; target.machineID = machine?.id; target.proxyID = proxy?.id
        target.localHost = localHost; target.localPort = localPort; target.targetHost = targetHost; target.targetPort = targetPort
        target.autoStart = autoStart; target.remark = remark
        if rule == nil { context.insert(target) }
    }
}
