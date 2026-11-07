import SwiftUI

struct SFTPSessionView: View {
    let session: SFTPSession
    @Environment(SessionManager.self) private var sessions
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var sheet: Sheet?
    @State private var renaming: SFTPSession.Entry?
    @State private var newName = ""
    @State private var copying: SFTPSession.Entry?
    @State private var pendingDelete: DeleteRequest?
    @State private var copyDestination = ""
    @AppStorage("sftpShowLocalPane") private var showLocal = false
    enum Sheet: Identifiable { case transfers, newFile, newDirectory; var id: Self { self } }

    private var rows: [SFTPSession.Entry] {
        session.visibleEntries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(session.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                if session.isLoading { ProgressView().controlSize(.small) }
                if let error = session.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(1) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if showLocal {
                HSplitView {
                    LocalFilePane(session: session).frame(minWidth: 260)
                    table.frame(minWidth: 360)
                }
            } else {
                table
            }
        }
        .navigationTitle(session.machine.displayName)
        .navigationSubtitle(session.stateText)
        .searchable(text: $query, prompt: "Search")
        .findShortcut()
        .deleteConfirmation($pendingDelete)
        .toolbar {
            ToolbarItemGroup {
                Button("Back", systemImage: "chevron.left") { session.goBack() }.disabled(!session.canGoBack)
                Button("Forward", systemImage: "chevron.right") { session.goForward() }.disabled(!session.canGoForward)
                Button("Up", systemImage: "arrow.up") { session.goUp() }.disabled(session.path == "/")
            }
            ToolbarItem {
                Toggle("This Mac", systemImage: "sidebar.left", isOn: $showLocal)
                    .help("Show this Mac's files beside the server's: drag between them to upload or download")
            }
            ToolbarItem { Button("Transfers", systemImage: "arrow.down.circle") { sheet = .transfers } }
            ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { session.refresh() } }
            ToolbarItem {
                Menu {
                    Text(session.stateText)
                    Button("Force Restart", systemImage: "arrow.clockwise") { session.restart() }
                    Divider()
                    Toggle("Show Hidden Files", isOn: Bindable(session).showHidden)
                    Divider()
                    Button("Upload File/Folder", systemImage: "square.and.arrow.up") { upload() }
                    Button("New File", systemImage: "doc.badge.plus") { newName = ""; sheet = .newFile }
                    Button("New Directory", systemImage: "folder.badge.plus") { newName = ""; sheet = .newDirectory }
                    Divider()
                    Button("Close Session", systemImage: "xmark.circle", role: .destructive) { sessions.close(session); state.selection = .machines }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .transfers: TransfersSheet(session: session)
            case .newFile: NameSheet(title: "New File", name: $newName) { name in Task { await session.createFile(name) } }
            case .newDirectory: NameSheet(title: "New Directory", name: $newName) { name in Task { await session.createDirectory(name) } }
            }
        }
        .sheet(item: $renaming) { e in NameSheet(title: "Rename", name: $newName) { name in Task { await session.rename(e, to: name) } } }
        .sheet(item: $copying) { e in NameSheet(title: "Copy to…", prompt: "Destination path", name: $copyDestination) { dest in Task { await session.copy(e, to: dest) } } }
    }

    private var table: some View {
        let list = rows
        return Table(of: SFTPSession.Entry.self, selection: $selection) {
            TableColumn("Name") { (e: SFTPSession.Entry) in EntryNameCell(entry: e) }.width(min: 200)
            TableColumn("Size") { (e: SFTPSession.Entry) in SecondaryText(e.sizeText) }.width(80)
            TableColumn("Type") { (e: SFTPSession.Entry) in SecondaryText(e.typeText) }.width(90)
            TableColumn("Permissions") { (e: SFTPSession.Entry) in SecondaryText(e.permissionText) }.width(100)
            TableColumn("Date Modified") { (e: SFTPSession.Entry) in SecondaryText(e.modifiedText) }.width(150)
            TableColumn("User") { (e: SFTPSession.Entry) in SecondaryText(e.ownerText) }.width(70)
        } rows: {
            // Rows drag onto the local pane, which downloads them (folders with everything in them).
            ForEach(list) { entry in TableRow(entry).draggable(LocalFilePane.dragPayload(session: session, path: entry.path)) }
        }
        .contextMenu(forSelectionType: String.self) { (ids: Set<String>) in
            if let e = entry(in: ids) { entryMenu(e) }
        } primaryAction: { (ids: Set<String>) in
            if let e = entry(in: ids) { open(e) }
        }
        // Files and folders dragged in from Finder upload into the folder shown.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            files.forEach(session.upload)
            sheet = .transfers
            return true
        }
    }

    private func entry(in ids: Set<String>) -> SFTPSession.Entry? { rows.first { ids.contains($0.id) } }

    private func upload() {
        FilePanel.openFilesOrFolders(title: "Upload to \(session.path)",
                                     message: "Files are uploaded to \(session.path) on \(session.machine.displayName).")
            .forEach(session.upload)
    }

    private func download(_ entry: SFTPSession.Entry) {
        if entry.isDirectory {
            guard let folder = FilePanel.openDirectory(title: "Download \(entry.name) into…",
                                                       directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                                                       prompt: "Download") else { return }
            session.downloadFolder(entry, to: LocalFilePane.freeName(for: entry.name, in: folder))
            sheet = .transfers
            return
        }
        guard let url = FilePanel.saveFile(title: "Download \(entry.name)", suggestedName: entry.name,
                                           directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                                           prompt: "Download") else { return }
        session.download(entry, to: url)
    }

    private func open(_ e: SFTPSession.Entry) {
        if e.isDirectory || e.isSymlink { session.open(e) }
        else { openWindow(value: EditorTarget(sessionID: session.id, path: e.path, name: e.name)) }
    }

    @ViewBuilder private func entryMenu(_ e: SFTPSession.Entry) -> some View {
        Button("Open", systemImage: "arrow.right") { open(e) }
        Button("Rename", systemImage: "pencil") { newName = e.name; renaming = e }
        Button("Download", systemImage: "arrow.down.circle") { download(e) }
        Button("Copy to…", systemImage: "doc.on.doc") { copyDestination = (session.path as NSString).appendingPathComponent(e.name + " copy"); copying = e }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            pendingDelete = .confirm(kind: e.isDirectory ? "Directory" : "File", name: e.name,
                                     note: "It is deleted on \(session.machine.displayName) at \(e.path).") {
                Task { await session.delete(e) }
            }
        }
    }
}

struct EntryNameCell: View {
    let entry: SFTPSession.Entry
    var body: some View {
        Label { Text(entry.name) } icon: { Image(systemName: entry.icon) }
            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.primary)
    }
}

struct SecondaryText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).foregroundStyle(.secondary).monospacedDigit() }
}

struct NameSheet: View {
    let title: String
    var prompt = "Name"
    @Binding var name: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(prompt, text: $name).textFieldStyle(.roundedBorder).onSubmit(submit)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("OK", action: submit).keyboardShortcut(.defaultAction).disabled(name.isEmpty) }
        }
        .padding(16).frame(width: 380)
    }
    private func submit() { guard !name.isEmpty else { return }; onDone(name); dismiss() }
}

struct TransfersSheet: View {
    let session: SFTPSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Text("File Transfer").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            Divider()
            Form {
                Section("Download") {
                    if session.downloads.isEmpty { Text("No downloads yet").foregroundStyle(.secondary) }
                    ForEach(session.downloads) { row($0) }
                }
                Section("Upload") {
                    Button("Select File or Folder to Upload") {
                        FilePanel.openFilesOrFolders(title: "Upload to \(session.path)").forEach(session.upload)
                    }
                    ForEach(session.uploads) { row($0) }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack { Button("Clear") { session.clearTransfers() }; Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 500, height: 440)
    }
    private func row(_ t: SFTPSession.Transfer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name).lineLimit(1)
                if t.isRunning, t.total > 0 {
                    Text(detail(t)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            if let e = t.error {
                Text(e).font(.caption).foregroundStyle(e == "Cancelled" ? Color.secondary : Color.red).lineLimit(1)
                Button("Retry", systemImage: "arrow.clockwise") { session.retryTransfer(t.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Start this transfer again")
            } else if t.done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
            } else {
                if t.queued { Text("Queued").font(.caption).foregroundStyle(.secondary) }
                else { ProgressView(value: t.progress).frame(width: 120) }
                Button("Cancel", systemImage: "xmark.circle.fill") { session.cancelTransfer(t.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel this transfer")
            }
        }
    }

    /// "12.3 M of 40 M · 5.2 M/s · 6 s left"
    private func detail(_ t: SFTPSession.Transfer) -> String {
        var parts = ["\(Format.short(t.bytes)) of \(Format.short(t.total))"]
        if t.speed > 0 { parts.append(Format.short(Int64(t.speed)) + "/s") }
        if let left = t.remaining { parts.append(left < 60 ? "\(Int(left.rounded())) s left" : "\(Format.uptime(left)) left") }
        return parts.joined(separator: " · ")
    }
}

/// Identifies a remote file opened in its own editor window.
struct EditorTarget: Hashable, Codable {
    let sessionID: UUID
    let path: String
    let name: String
}

struct RemoteFileEditorView: View {
    let target: EditorTarget
    @Environment(SessionManager.self) private var sessions
    @State private var text = ""
    @State private var original = ""
    @State private var status = "Loading…"
    @State private var saving = false

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .navigationTitle(target.name)
            .navigationSubtitle(status)
            .toolbar { ToolbarItem { Button("Save", action: save).disabled(text == original || saving).keyboardShortcut("s", modifiers: .command) } }
            .task { await load() }
            .frame(minWidth: 500, minHeight: 360)
    }

    private func load() async {
        guard let session = sessions.sftp(target.sessionID), let entry = session.entries.first(where: { $0.path == target.path }) else { status = "Session closed"; return }
        do {
            let data = try await session.readFile(entry)
            original = String(decoding: data, as: UTF8.self); text = original
            status = "\(Format.short(Int64(data.count))) · \(target.path)"
        } catch { status = error.localizedDescription }
    }

    private func save() {
        guard let session = sessions.sftp(target.sessionID) else { return }
        saving = true
        Task {
            do { try await session.writeFile(target.path, data: Data(text.utf8)); original = text; status = "Saved" }
            catch { status = error.localizedDescription }
            saving = false
        }
    }
}
