import SwiftUI
import AppKit

/// The Mac's side of the SFTP window: browse a local folder, drag files to the remote pane to upload them, and
/// drop remote files here to download them into the folder shown.
struct LocalFilePane: View {
    struct Item: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
        var name: String { url.lastPathComponent }
    }

    let session: SFTPSession
    @AppStorage("sftpLocalFolder") private var folderPath = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var items: [Item] = []
    @State private var selection: Set<URL> = []
    @State private var showHidden = false
    @State private var error: String?

    private var folder: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    /// What a remote row carries when dragged: this session and the file's path.
    static func dragPayload(session: SFTPSession, path: String) -> String { "swiftpulse-sftp://\(session.id.uuidString)\(path)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("Up", systemImage: "arrow.up") { open(folder.deletingLastPathComponent()) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(folder.path == "/")
                Text((folder.path as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Toggle("Hidden", isOn: $showHidden).toggleStyle(.button).controlSize(.small).help("Show hidden files")
                Button("Refresh", systemImage: "arrow.clockwise") { load() }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            Table(of: Item.self, selection: $selection) {
                TableColumn("Name") { item in
                    Label { Text(item.name) } icon: { Image(systemName: item.isDirectory ? "folder.fill" : "doc") }
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.primary)
                }.width(min: 160)
                TableColumn("Size") { item in SecondaryText(item.isDirectory ? "--" : Format.short(item.size)) }.width(70)
                TableColumn("Date Modified") { item in
                    SecondaryText(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                }.width(140)
            } rows: {
                ForEach(items) { item in TableRow(item).draggable(item.url) }
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first {
                    Button("Upload to \(session.path)", systemImage: "square.and.arrow.up") { urls.forEach(session.upload) }
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } primaryAction: { urls in
                guard let url = urls.first, let item = items.first(where: { $0.url == url }) else { return }
                if item.isDirectory { open(url) } else { NSWorkspace.shared.open(url) }
            }
            .dropDestination(for: String.self) { payloads, _ in
                let paths = payloads.compactMap(remotePath)
                guard !paths.isEmpty else { return false }
                for path in paths {
                    guard let entry = session.entries.first(where: { $0.path == path }) else { continue }
                    let target = Self.freeName(for: entry.name, in: folder)
                    if entry.isDirectory { session.downloadFolder(entry, to: target) } else { session.download(entry, to: target) }
                }
                return true
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(6) }
        }
        .onAppear(perform: load)
        .onChange(of: folderPath) { load() }
        .onChange(of: showHidden) { load() }
        .onChange(of: session.downloads.filter(\.done).count) { load() } // a finished download shows up
    }

    /// The remote path in a payload dragged from this session, nil for anything else.
    private func remotePath(_ payload: String) -> String? {
        let prefix = Self.dragPayload(session: session, path: "")
        return payload.hasPrefix(prefix) ? String(payload.dropFirst(prefix.count)) : nil
    }

    private func open(_ url: URL) {
        folderPath = url.standardizedFileURL.path
        selection = []
    }

    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: showHidden ? [] : [.skipsHiddenFiles])
            items = urls.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Item(url: url, isDirectory: values?.isDirectory ?? false, size: Int64(values?.fileSize ?? 0),
                            modified: values?.contentModificationDate)
            }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
            error = nil
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }

    /// `name`, or "name 2.ext", "name 3.ext"… so a download never replaces a file already there.
    static func freeName(for name: String, in folder: URL, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while exists(candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
