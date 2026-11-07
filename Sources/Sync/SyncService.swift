import Foundation
import SwiftData
import CryptoKit
import AppKit

/// Local sync: writes an encrypted vault into a folder you already sync yourself (Nextcloud, Dropbox,
/// a USB stick) and imports it back on another Mac. No account, no server, no iCloud.
@Observable @MainActor
final class SyncService {
    enum Keys {
        static let folder = "syncFolderPath"
        static let auto = "syncAutoExport"
        static let lastExport = "syncLastExport"
        static let lastImport = "syncLastImport"
        static let fingerprint = "syncFingerprint"
        static let passphrase = "sync.passphrase"
        static let fileName = "SwiftPulse.spvault"
    }

    private let container: ModelContainer
    private var pending: Task<Void, Never>?

    var folderPath: String {
        didSet { UserDefaults.standard.set(folderPath, forKey: Keys.folder) }
    }
    var autoExport: Bool {
        didSet { UserDefaults.standard.set(autoExport, forKey: Keys.auto) }
    }
    var passphrase: String {
        didSet { KeychainService.set(passphrase.isEmpty ? nil : passphrase, for: Keys.passphrase) }
    }
    private(set) var lastExport: Date?
    private(set) var lastImport: Date?
    private(set) var status: String?
    private(set) var error: String?
    private(set) var busy = false

    init(container: ModelContainer) {
        self.container = container
        let defaults = UserDefaults.standard
        folderPath = defaults.string(forKey: Keys.folder) ?? ""
        autoExport = defaults.object(forKey: Keys.auto) as? Bool ?? true
        passphrase = KeychainService.get(Keys.passphrase) ?? ""
        lastExport = defaults.object(forKey: Keys.lastExport) as? Date
        lastImport = defaults.object(forKey: Keys.lastImport) as? Date
    }

    var isConfigured: Bool { !folderPath.isEmpty && !passphrase.isEmpty }
    var vaultURL: URL? {
        folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath).appendingPathComponent(Keys.fileName)
    }
    var vaultExists: Bool { vaultURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// Cleartext header of the vault currently in the folder, so the UI can show what is there
    /// (device, date) before anyone types a passphrase.
    func remoteEnvelope() -> VaultEnvelope? {
        guard let url = vaultURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? SyncVault.envelope(from: data)
    }

    // MARK: - export

    func exportNow() {
        Task { await export(auto: false) }
    }

    /// Writes the vault. Automatic exports skip the write when nothing changed since the last one.
    func export(auto: Bool) async {
        guard let url = vaultURL else { if !auto { error = "Choose a sync folder first." }; return }
        guard !passphrase.isEmpty else { if !auto { error = "Set a sync passphrase first." }; return }
        busy = true
        defer { busy = false }
        do {
            let vault = try SyncVault.build(from: container.mainContext)
            let plaintext = try SyncVault.encoder().encode(vault)
            let fingerprint = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
            if auto, fingerprint == UserDefaults.standard.string(forKey: Keys.fingerprint) { return }

            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try vault.fileData(passphrase: passphrase).write(to: url, options: .atomic)

            UserDefaults.standard.set(fingerprint, forKey: Keys.fingerprint)
            lastExport = Date()
            UserDefaults.standard.set(lastExport, forKey: Keys.lastExport)
            status = "Exported \(vault.machines.count) machines, \(vault.identities.count) identities, \(vault.sshKeys.count) keys"
            error = nil
            debugLog("[sync] exported vault to \(url.path)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - import

    func read(from url: URL) throws -> (SyncVault, VaultEnvelope) {
        try SyncVault.read(try Data(contentsOf: url), passphrase: passphrase)
    }

    @discardableResult
    func apply(_ vault: SyncVault, strategy: SyncVault.Strategy) -> SyncVault.Summary? {
        busy = true
        defer { busy = false }
        do {
            let summary = try SyncVault.apply(vault, to: container.mainContext, strategy: strategy)
            lastImport = Date()
            UserDefaults.standard.set(lastImport, forKey: Keys.lastImport)
            UserDefaults.standard.removeObject(forKey: Keys.fingerprint)  // local state differs from the file now
            status = "Imported: \(summary.inserted) added, \(summary.updated) updated, \(summary.deleted) removed"
            error = nil
            return summary
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func reportImportFailure(_ failure: Error) {
        error = failure.localizedDescription
        status = nil
    }

    // MARK: - automatic export

    /// Re-exports a few seconds after the store or the settings change, so the folder is always current.
    func start() {
        let center = NotificationCenter.default
        for name in [ModelContext.didSave, UserDefaults.didChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        }
        schedule()
    }

    private func schedule() {
        guard autoExport, isConfigured else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.export(auto: true)
        }
    }

    /// Directory picker. The app is not sandboxed, so the chosen path is usable as-is.
    func chooseFolder() {
        guard let url = FilePanel.openDirectory(
            title: "Sync Folder",
            message: "Pick a folder inside your own cloud storage (for example ~/Nextcloud/SwiftPulse).",
            directory: folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath),
            prompt: "Use Folder") else { return }
        folderPath = url.path
        status = nil
        error = nil
        if autoExport { exportNow() }
    }

    func revealInFinder() {
        guard !folderPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(vaultExists ? vaultURL?.path : nil, inFileViewerRootedAtPath: folderPath)
    }
}
