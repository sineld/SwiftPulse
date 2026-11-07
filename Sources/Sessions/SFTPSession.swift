import Foundation
import Citadel
import NIOCore
import SwiftData
import AppKit

/// One SFTP browser session: connection, current directory listing, transfers.
@Observable @MainActor
final class SFTPSession: Identifiable {
    struct Entry: Identifiable, Hashable {
        let name: String
        let path: String
        let size: UInt64
        let permissions: UInt32
        let modified: Date?
        let owner: String
        let isDirectory: Bool, isSymlink: Bool
        var id: String { path }
        var typeText: String { isSymlink ? "Symbolic Link" : isDirectory ? "Directory" : "File" }
        var ownerText: String { owner }
        var sizeText: String { isDirectory ? "--" : Format.short(Int64(size)) }
        var modifiedText: String { modified?.formatted(date: .abbreviated, time: .shortened) ?? "" }
        var icon: String { isDirectory ? "folder.fill" : isSymlink ? "arrow.triangle.turn.up.right.diamond" : "doc" }
        var permissionText: String {
            let bits = permissions & 0o777
            let chars = ["r", "w", "x"]
            var s = isDirectory ? "d" : isSymlink ? "l" : "-"
            for shift in stride(from: 6, through: 0, by: -3) { for (i, c) in chars.enumerated() { s += (bits >> UInt32(shift)) & UInt32(4 >> i) != 0 ? c : "-" } }
            return s
        }
    }
    struct Transfer: Identifiable {
        let id = UUID()
        let name: String
        var progress: Double
        var done = false
        var error: String?
        var bytes: Int64 = 0
        var total: Int64 = 0
        /// Waiting for one of the running transfers to end.
        var queued = true
        let started = Date()
        var isRunning: Bool { !done && error == nil }
        /// Bytes per second so far.
        var speed: Double { bytes > 0 ? Double(bytes) / max(Date().timeIntervalSince(started), 0.1) : 0 }
        /// Seconds left at that speed; nil until there is one.
        var remaining: TimeInterval? { speed > 0 && total > bytes ? Double(total - bytes) / speed : nil }
    }
    enum State: Equatable { case connecting, running, closed(String?) }

    let id = UUID()
    let machine: Machine
    let record: SessionRecord
    private(set) var state: State = .connecting
    private(set) var path = "/"
    private(set) var entries: [Entry] = []
    private(set) var isLoading = false
    var showHidden = false
    var error: String?
    var downloads: [Transfer] = []
    var uploads: [Transfer] = []
    private var history: [String] = []
    private var forwardStack: [String] = []
    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    private let container: ModelContainer
    private var client: SSHClient?
    private var sftp: SFTPClient?
    /// Running transfers' tasks (for Cancel) and how to start each one again (for Retry), by transfer id.
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var retries: [UUID: () -> Void] = [:]
    /// At most this many transfers move data at once; the rest wait their turn (browsing shares the connection).
    static let concurrentTransfers = 2
    private var activeTransfers = 0
    private var waitingTransfers: [CheckedContinuation<Void, Never>] = []
    private var users: [UInt32: String] = [:]
    private var groups: [UInt32: String] = [:]

    var stateText: String {
        switch state {
        case .connecting: "SFTP · Connecting"; case .running: "SFTP · Running"; case .closed(let e): e.map { "SFTP · \($0)" } ?? "SFTP · Closed"
        }
    }
    var visibleEntries: [Entry] { entries.filter { showHidden || !$0.name.hasPrefix(".") } }

    init(machine: Machine, record: SessionRecord, container: ModelContainer, path start: String? = nil) {
        self.machine = machine; self.record = record; self.container = container
        path = start ?? (machine.defaultSFTPPath.isEmpty ? "/" : machine.defaultSFTPPath)
        Task { await connect() }
    }

    func connect() async {
        state = .connecting; error = nil
        do {
            let spec = try ConnectionSpec.make(for: machine, in: ModelContext(container))
            let client = try await SSHService.connect(spec, container: container)
            self.client = client
            sftp = try await client.openSFTP()
            state = .running
            await loadOwners()
            await load(path)
        } catch { state = .closed(error.localizedDescription); self.error = error.localizedDescription }
    }

    /// uid/gid → names from the remote passwd/group databases (best effort, one round trip).
    private func loadOwners() async {
        guard let client, let out = try? await client.executeCommand("getent passwd; echo '##'; getent group", maxResponseSize: 1 << 20, mergeStreams: false, inShell: false) else { return }
        let parts = String(buffer: out).components(separatedBy: "##\n")
        func parse(_ text: String) -> [UInt32: String] {
            var map: [UInt32: String] = [:]
            for line in text.split(separator: "\n") { let f = line.split(separator: ":"); if f.count > 2, let id = UInt32(f[2]) { map[id] = String(f[0]) } }
            return map
        }
        users = parse(parts.first ?? ""); groups = parse(parts.count > 1 ? parts[1] : "")
    }

    func restart() { close(keepState: true); Task { await connect() } }

    func close(keepState: Bool = false) {
        let s = sftp, c = client; sftp = nil; client = nil
        Task { try? await s?.close(); try? await c?.close() }
        if !keepState { state = .closed(nil); record.lastActiveAt = .now }
    }

    // MARK: navigation
    func open(_ entry: Entry) {
        guard entry.isDirectory || entry.isSymlink else { return }
        navigate(to: entry.path)
    }
    func navigate(to newPath: String) {
        history.append(path); forwardStack.removeAll()
        Task { await load(newPath) }
    }
    func goBack() { guard let p = history.popLast() else { return }; forwardStack.append(path); Task { await load(p) } }
    func goForward() { guard let p = forwardStack.popLast() else { return }; history.append(path); Task { await load(p) } }
    func goUp() { navigate(to: (path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent) }
    func refresh() { Task { await load(path) } }

    func load(_ target: String) async {
        guard let sftp else { return }
        isLoading = true; defer { isLoading = false }
        do {
            let real = try await sftp.getRealPath(atPath: target)
            let names = try await sftp.listDirectory(atPath: real)
            var list: [Entry] = []
            for name in names { for c in name.components where c.filename != "." && c.filename != ".." {
                let a = c.attributes
                let type = (a.permissions ?? 0) & 0o170000
                list.append(Entry(name: c.filename, path: (real as NSString).appendingPathComponent(c.filename), size: a.size ?? 0,
                                  permissions: a.permissions ?? 0, modified: a.accessModificationTime?.modificationTime,
                                  owner: a.uidgid.map { "\(users[$0.userId] ?? "\($0.userId)"):\(groups[$0.groupId] ?? "\($0.groupId)")" } ?? "",
                                  isDirectory: type == 0o040000, isSymlink: type == 0o120000))
            } }
            entries = list.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
            path = real
            record.lastActiveAt = .now
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    // MARK: file operations
    func readFile(_ entry: Entry) async throws -> Data {
        guard let sftp else { throw SFTPError.notConnected }
        return try await sftp.withFile(filePath: entry.path, flags: .read) { file in Data(buffer: try await file.readAll()) }
    }
    func writeFile(_ path: String, data: Data) async throws {
        guard let sftp else { throw SFTPError.notConnected }
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in try await file.write(ByteBuffer(data: data), at: 0) }
        refresh()
    }
    func rename(_ entry: Entry, to newName: String) async {
        guard let sftp else { return }
        do { try await sftp.rename(at: entry.path, to: (path as NSString).appendingPathComponent(newName)); refresh() }
        catch { self.error = error.localizedDescription }
    }
    func delete(_ entry: Entry) async {
        guard let sftp else { return }
        do { if entry.isDirectory { try await sftp.rmdir(at: entry.path) } else { try await sftp.remove(at: entry.path) }; refresh() }
        catch { self.error = error.localizedDescription }
    }
    func createDirectory(_ name: String) async {
        guard let sftp else { return }
        do { try await sftp.createDirectory(atPath: (path as NSString).appendingPathComponent(name)); refresh() }
        catch { self.error = error.localizedDescription }
    }
    func createFile(_ name: String) async {
        do { try await writeFile((path as NSString).appendingPathComponent(name), data: Data()) }
        catch { self.error = error.localizedDescription }
    }
    func copy(_ entry: Entry, to destination: String) async {
        guard let client else { return }
        do { _ = try await client.executeCommand("cp -a \(shellQuote(entry.path)) \(shellQuote(destination))", maxResponseSize: 4096, mergeStreams: true, inShell: false); refresh() }
        catch { self.error = error.localizedDescription }
    }

    /// Streams a remote file to a local URL (security-scoped) with progress.
    func download(_ entry: Entry, to url: URL) {
        var transfer = Transfer(name: entry.name, progress: 0)
        transfer.total = Int64(entry.size)
        downloads.append(transfer)
        let id = transfer.id
        retries[id] = { [weak self] in self?.download(entry, to: url) }
        transferTasks[id] = Task {
            defer { transferTasks[id] = nil }
            guard await acquireSlot(id, in: \.downloads) else { return }
            defer { releaseSlot() }
            do {
                guard let sftp else { throw SFTPError.notConnected }
                let accessing = url.startAccessingSecurityScopedResource(); defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                var received: Int64 = 0
                try await receive(entry.path, to: url, with: sftp) { bytes in
                    received += Int64(bytes)
                    let done = received
                    self.update(id, in: \.downloads) { $0.progress = entry.size > 0 ? Double(done) / Double(entry.size) : 1; $0.bytes = done }
                }
                update(id, in: \.downloads) { $0.done = true; $0.progress = 1 }
            } catch {
                update(id, in: \.downloads) { $0.error = error is CancellationError ? "Cancelled" : error.localizedDescription }
            }
        }
    }

    /// Downloads a folder with everything in it into `url`, which is created. Symbolic links aren't followed.
    func downloadFolder(_ entry: Entry, to url: URL) {
        let transfer = Transfer(name: entry.name + "/", progress: 0)
        downloads.append(transfer)
        let id = transfer.id
        retries[id] = { [weak self] in self?.downloadFolder(entry, to: url) }
        transferTasks[id] = Task {
            defer { transferTasks[id] = nil }
            guard await acquireSlot(id, in: \.downloads) else { return }
            defer { releaseSlot() }
            do {
                guard let sftp else { throw SFTPError.notConnected }
                let tree = try await Self.walk(entry.path) { path in
                    try await sftp.listDirectory(atPath: path).flatMap(\.components).map { c in
                        (c.filename, (c.attributes.permissions ?? 0) & 0o170000, Int64(c.attributes.size ?? 0))
                    }
                }
                let size = tree.files.reduce(0) { $0 + $1.size }
                update(id, in: \.downloads) { $0.total = size }
                for directory in [""] + tree.directories {
                    try FileManager.default.createDirectory(at: url.appendingPathComponent(directory), withIntermediateDirectories: true)
                }
                var received: Int64 = 0
                for file in tree.files {
                    try await receive(file.path, to: url.appendingPathComponent(file.relative), with: sftp) { bytes in
                        received += Int64(bytes)
                        let done = received
                        self.update(id, in: \.downloads) { $0.progress = Double(done) / Double(max(size, 1)); $0.bytes = done }
                    }
                }
                update(id, in: \.downloads) { $0.done = true; $0.progress = 1 }
            } catch {
                update(id, in: \.downloads) { $0.error = error is CancellationError ? "Cancelled" : error.localizedDescription }
            }
        }
    }

    /// Everything under a remote folder: its subfolders and its regular files (path, path relative to the folder,
    /// size). `list` gives a directory's entries as (name, file type bits, size). Links aren't followed, so a loop
    /// can't make it endless; nor can depth beyond 64.
    nonisolated static func walk(_ root: String, depth: Int = 0,
                                 list: (String) async throws -> [(name: String, type: UInt32, size: Int64)]) async throws
        -> (directories: [String], files: [(path: String, relative: String, size: Int64)]) {
        guard depth < 64 else { return ([], []) }
        var directories: [String] = [], files: [(path: String, relative: String, size: Int64)] = []
        for item in try await list(root) where item.name != "." && item.name != ".." {
            let path = (root as NSString).appendingPathComponent(item.name)
            switch item.type {
            case 0o040000:
                directories.append(item.name)
                let inner = try await walk(path, depth: depth + 1, list: list)
                directories += inner.directories.map { item.name + "/" + $0 }
                files += inner.files.map { ($0.path, item.name + "/" + $0.relative, $0.size) }
            case 0o100000:
                files.append((path, item.name, item.size))
            default:
                continue // links, sockets, devices
            }
        }
        return (directories, files)
    }

    /// Reads a remote file into a local one in chunks. Servers may answer a read with fewer bytes than asked, so
    /// only an empty read (end of file) ends it. A cancelled read leaves no half file behind.
    private func receive(_ remote: String, to local: URL, with sftp: SFTPClient, progress: @escaping @MainActor (Int) -> Void) async throws {
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let handle = try FileHandle(forWritingTo: local)
        defer { try? handle.close() }
        do {
            try await sftp.withFile(filePath: remote, flags: .read) { file in
                var offset: UInt64 = 0
                while true {
                    let buffer = try await file.read(from: offset, length: 256 * 1024)
                    if buffer.readableBytes == 0 { break }
                    try Task.checkCancellation()
                    try handle.write(contentsOf: Data(buffer.readableBytesView))
                    offset += UInt64(buffer.readableBytes)
                    await progress(buffer.readableBytes)
                }
            }
        } catch {
            if error is CancellationError { try? FileManager.default.removeItem(at: local) }
            throw error
        }
    }

    /// Uploads a file, or a folder with everything in it, into the current directory. Files are read in chunks,
    /// so a large one never has to fit in memory.
    func upload(_ url: URL) {
        let transfer = Transfer(name: url.lastPathComponent, progress: 0)
        uploads.append(transfer)
        let id = transfer.id
        let destination = (path as NSString).appendingPathComponent(url.lastPathComponent)
        retries[id] = { [weak self] in self?.upload(url) }
        transferTasks[id] = Task {
            defer { transferTasks[id] = nil }
            guard await acquireSlot(id, in: \.uploads) else { return }
            defer { releaseSlot() }
            do {
                guard let sftp else { throw SFTPError.notConnected }
                let accessing = url.startAccessingSecurityScopedResource(); defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let plan = try Self.uploadPlan(from: url, to: destination)
                let size = plan.files.reduce(0) { $0 + $1.size }
                let total = Double(max(size, 1))
                update(id, in: \.uploads) { $0.total = size }
                var sent: Int64 = 0
                for directory in plan.directories { try await makeDirectory(directory, with: sftp) }
                for file in plan.files {
                    try await send(file.local, to: file.remote, with: sftp) { bytes in
                        sent += Int64(bytes)
                        let done = sent
                        self.update(id, in: \.uploads) { $0.progress = Double(done) / total; $0.bytes = done }
                    }
                }
                update(id, in: \.uploads) { $0.done = true; $0.progress = 1 }
                refresh()
            } catch {
                update(id, in: \.uploads) { $0.error = error is CancellationError ? "Cancelled" : error.localizedDescription }
                refresh()
            }
        }
    }

    /// The remote directories to create (parents first) and the files to send for a local file or folder. Hidden
    /// files are included; symbolic links to folders aren't followed, so a loop can't make it endless.
    nonisolated static func uploadPlan(from url: URL, to remote: String) throws
        -> (directories: [String], files: [(local: URL, remote: String, size: Int64)]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: Set(keys))
        guard values.isDirectory == true else { return ([], [(url, remote, Int64(values.fileSize ?? 0))]) }
        var directories = [remote], files: [(local: URL, remote: String, size: Int64)] = []
        let base = url.standardizedFileURL.path
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let item = items?.nextObject() as? URL {
            let relative = String(item.standardizedFileURL.path.dropFirst(base.count + 1))
            let target = (remote as NSString).appendingPathComponent(relative)
            let info = try item.resourceValues(forKeys: Set(keys))
            if info.isDirectory == true { directories.append(target) }
            else if info.isRegularFile == true { files.append((item, target, Int64(info.fileSize ?? 0))) }
        }
        return (directories, files)
    }

    /// mkdir, where a directory that is already there is fine.
    private func makeDirectory(_ path: String, with sftp: SFTPClient) async throws {
        do { try await sftp.createDirectory(atPath: path) } catch {
            guard (try? await sftp.getAttributes(at: path)) != nil else { throw error }
        }
    }

    private func send(_ local: URL, to remote: String, with sftp: SFTPClient, progress: @escaping @MainActor (Int) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        try await sftp.withFile(filePath: remote, flags: [.write, .create, .truncate]) { file in
            var offset: UInt64 = 0
            while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try await file.write(ByteBuffer(data: data), at: offset)
                offset += UInt64(data.count)
                await progress(data.count)
            }
        }
    }

    /// Changes one transfer by id: indexes shift when finished transfers are cleared while others still run.
    private func update(_ id: UUID, in list: ReferenceWritableKeyPath<SFTPSession, [Transfer]>, _ change: (inout Transfer) -> Void) {
        guard let index = self[keyPath: list].firstIndex(where: { $0.id == id }) else { return }
        change(&self[keyPath: list][index])
    }

    func cancelTransfer(_ id: UUID) {
        transferTasks[id]?.cancel()
        // A queued one shows it at once; its task leaves as soon as it gets a turn.
        for list in [\SFTPSession.downloads, \SFTPSession.uploads] {
            update(id, in: list) { if $0.queued { $0.error = "Cancelled" } }
        }
    }

    /// Waits for a free transfer slot; false when the transfer was cancelled meanwhile (the slot is handed on).
    private func acquireSlot(_ id: UUID, in list: ReferenceWritableKeyPath<SFTPSession, [Transfer]>) async -> Bool {
        if activeTransfers < Self.concurrentTransfers { activeTransfers += 1 }
        else { await withCheckedContinuation { waitingTransfers.append($0) } } // a finishing transfer hands its slot over
        guard !Task.isCancelled else { releaseSlot(); return false }
        update(id, in: list) { $0.queued = false }
        return true
    }

    private func releaseSlot() {
        if waitingTransfers.isEmpty { activeTransfers -= 1 } else { waitingTransfers.removeFirst().resume() }
    }

    /// Starts a failed or cancelled transfer again, in place of its row.
    func retryTransfer(_ id: UUID) {
        guard let retry = retries.removeValue(forKey: id) else { return }
        downloads.removeAll { $0.id == id }
        uploads.removeAll { $0.id == id }
        retry()
    }

    /// Removes finished, failed and cancelled transfers; running ones stay.
    func clearTransfers() {
        for transfer in downloads + uploads where !transfer.isRunning { retries[transfer.id] = nil }
        downloads.removeAll { !$0.isRunning }
        uploads.removeAll { !$0.isRunning }
    }

    enum SFTPError: LocalizedError { case notConnected; var errorDescription: String? { "SFTP is not connected." } }
    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
