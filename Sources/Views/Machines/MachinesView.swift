import SwiftUI
import SwiftData

struct MachinesView: View {
    @Query(sort: \MachineGroup.name) private var groups: [MachineGroup]
    @Query(sort: \Machine.name) private var machines: [Machine]
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var context
    @Environment(SessionManager.self) private var sessions
    @State private var sheet: Sheet?
    @State private var pendingDelete: DeleteRequest?
    @State private var tagFilter: String? = nil
    @State private var path: [MachineGroup] = []

    enum Sheet: Identifiable {
        case newMachine, newGroup, importSSHConfig, edit(Machine), duplicate(Machine), editGroup(MachineGroup)
        var id: String {
            switch self {
            case .newMachine: "newMachine"
            case .newGroup: "newGroup"
            case .importSSHConfig: "importSSHConfig"
            case .edit(let m): "edit-\(m.id)"
            case .duplicate(let m): "dup-\(m.id)"
            case .editGroup(let g): "group-\(g.id)"
            }
        }
    }

    private var visibleGroups: [MachineGroup] {
        groups.filter { state.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(state.searchText) }
    }
    private var allTags: [String] { Array(Set(machines.flatMap(\.tags))).sorted() }
    private var visibleMachines: [Machine] {
        machines.filtered(by: state).filter { m in
            switch tagFilter {
            case nil: true
            case "": m.tags.isEmpty
            case let t?: m.tags.contains(t)
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Page(title: "Machines") {
                if !visibleGroups.isEmpty {
                    SectionTitle(text: "Groups")
                    CardGrid(items: visibleGroups) { group in
                        NavigationLink(value: group) {
                            ResourceCard(icon: "square.grid.2x2", title: group.name, subtitle: "\(group.machines?.count ?? 0) Machine\(group.machines?.count == 1 ? "" : "s")")
                        }
                        .buttonStyle(.plain)
                        .contextMenu { groupMenu(group) }
                    }
                }
                SectionTitle(text: "Machines")
                TagFilterBar(tags: allTags, selection: $tagFilter)
                if machines.isEmpty {
                    EmptyStateView(message: "No machines available, create one now!", buttonTitle: "Create New Machine") { sheet = .newMachine }
                } else {
                    CardGrid(items: visibleMachines) { machine in
                        MachineCard(machine: machine)
                            .onTapGesture(count: 2) { state.selection = .terminalSession(sessions.openTerminal(machine).id) }
                            .contextMenu { machineMenu(machine) }
                    }
                }
            }
            .navigationDestination(for: MachineGroup.self) { GroupDetailView(group: $0) }
            .searchable(text: Bindable(state).searchText)
            .findShortcut()
        }
        .deleteConfirmation($pendingDelete)
        .toolbar {
            ResourceToolbar()
            ToolbarItem {
                Menu {
                    Button("Create New Machine", systemImage: "server.rack") { sheet = .newMachine }
                    Divider()
                    Button("Create New Group", systemImage: "square.grid.2x2") { sheet = .newGroup }
                    Divider()
                    Button("Import from SSH Config…", systemImage: "doc.text") { sheet = .importSSHConfig }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .newMachine: MachineFormSheet()
            case .newGroup: GroupFormSheet()
            case .importSSHConfig: SSHConfigImportSheet()
            case .edit(let m): MachineFormSheet(machine: m)
            case .duplicate(let m): MachineFormSheet(duplicateOf: m)
            case .editGroup(let g): GroupFormSheet(group: g)
            }
        }
    }

    @ViewBuilder private func machineMenu(_ machine: Machine) -> some View {
        Button("Start Terminal", systemImage: "terminal") { state.selection = .terminalSession(sessions.openTerminal(machine).id) }
        Button("Start SFTP", systemImage: "folder") { state.selection = .sftpSession(sessions.openSFTP(machine).id) }
        Divider()
        Button("Edit", systemImage: "pencil") { sheet = .edit(machine) }
        Button("Duplicate", systemImage: "plus.square.on.square") { sheet = .duplicate(machine) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            let live = sessions.sessionCount(for: machine)
            pendingDelete = .confirm(kind: "Machine", name: machine.displayName,
                                     note: live > 0 ? "Active sessions for this machine will be stopped." : nil) {
                sessions.closeSessions(for: machine)
                KeychainService.delete(machine.passwordKey)
                context.delete(machine)
            }
        }
    }

    @ViewBuilder private func groupMenu(_ group: MachineGroup) -> some View {
        Button("Batch Start Terminals", systemImage: "terminal") {
            var last: TerminalSession?
            for m in group.machines ?? [] { last = sessions.openTerminal(m) }
            if let last { state.selection = .terminalSession(last.id) }
        }
        Button("Batch Start SFTP", systemImage: "folder") {
            var last: SFTPSession?
            for m in group.machines ?? [] { last = sessions.openSFTP(m) }
            if let last { state.selection = .sftpSession(last.id) }
        }
        Divider()
        Button("Edit", systemImage: "pencil") { sheet = .editGroup(group) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            pendingDelete = .confirm(kind: "Group", name: group.name,
                                     note: "The machines in it are kept.") { context.delete(group) }
        }
    }
}

struct MachineCard: View {
    let machine: Machine
    @Environment(AppState.self) private var state
    @AppStorage("showServerListTags") private var showTags = true
    var body: some View {
        ResourceCard(icon: "server.rack", title: machine.displayName,
                     subtitle: state.hideHost ? nil : machine.host,
                     badges: showTags ? (machine.tags.isEmpty ? ["No Tags"] : machine.tags) : [])
    }
}

/// "All / No Tags / tag…" capsule filter row.
struct TagFilterBar: View {
    let tags: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", value: nil)
                chip("No Tags", value: "")
                ForEach(tags, id: \.self) { chip($0, value: $0) }
            }
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        Button {
            selection = value
        } label: {
            Label(title, systemImage: selection == value ? "largecircle.fill.circle" : "circle")
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selection == value ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct GroupDetailView: View {
    let group: MachineGroup
    @Environment(\.modelContext) private var context
    @State private var editing: Machine?

    var body: some View {
        Page(title: group.name) {
            let machines = (group.machines ?? []).sorted { $0.displayName < $1.displayName }
            if machines.isEmpty {
                ContentUnavailableView("No machines in this group", systemImage: "square.grid.2x2").frame(maxWidth: .infinity, minHeight: 200).card()
            } else {
                CardGrid(items: machines) { machine in
                    MachineCard(machine: machine).contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = machine }
                        Button("Remove from Group", systemImage: "minus.circle") { machine.group = nil }
                    }
                }
            }
        }
        .sheet(item: $editing) { MachineFormSheet(machine: $0) }
    }
}

struct GroupFormSheet: View {
    @Environment(\.modelContext) private var context
    var group: MachineGroup?
    var onSaved: ((MachineGroup) -> Void)? = nil
    @State private var name = ""
    @State private var remark = Machine.defaultRemark()

    var body: some View {
        FormSheet(title: group == nil ? "Create New Group" : "Edit Group", canSave: !name.isEmpty, onSave: save) {
            Section("Group Information") { TextField("Name", text: $name, prompt: Text("Name")) }
            Section("Remark") { TextField("Group Remark", text: $remark, axis: .vertical) }
        }
        .onAppear { if let group { name = group.name; remark = group.remark } }
    }

    private func save() {
        let target = group ?? MachineGroup()
        target.name = name; target.remark = remark
        if group == nil { context.insert(target) }
        onSaved?(target)
    }
}
