import Foundation

/// Where SwiftPulse keeps its data. The app is not sandboxed (it is a personal build, not an App Store
/// submission), so everything lives in a normal `~/Library/Application Support/SwiftPulse` folder and any
/// user-chosen sync folder can be read and written directly.
enum AppPaths {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SwiftPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var store: URL { directory.appendingPathComponent("SwiftPulse.store") }
    static var secrets: URL { directory.appendingPathComponent("secrets.json") }
    /// The MCP server's Unix socket (see `AgentSocket`); `swiftpulse-mcp` relays agents to it.
    static var agentSocket: URL { directory.appendingPathComponent("agent.sock") }

    /// Application Support inside the old sandbox container, from the sandboxed builds.
    private static var legacyContainer: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/app.swiftpulse.macos/Data/Library/Application Support", isDirectory: true)
    }

    /// Copies the preferences an earlier sandboxed build wrote inside the container: leaving the sandbox
    /// moves UserDefaults to a different domain, which would otherwise reset every setting.
    static func migrateLegacyPreferencesIfNeeded() {
        let defaults = UserDefaults.standard
        let marker = "didMigrateSandboxPreferences"
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)
        let plist = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/app.swiftpulse.macos/Data/Library/Preferences/app.swiftpulse.macos.plist")
        guard let stored = NSDictionary(contentsOf: plist) as? [String: Any] else { return }
        let systemPrefixes = ["NS", "Apple", "com.apple."]
        for (key, value) in stored where defaults.object(forKey: key) == nil {
            guard !systemPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            defaults.set(value, forKey: key)
        }
    }

    /// Copies the store and secrets written by an earlier sandboxed build. Runs once, before the
    /// ModelContainer opens, and never overwrites newer data.
    static func migrateLegacyDataIfNeeded() {
        let fm = FileManager.default
        // Only the first launch outside the sandbox migrates: once the store exists, a missing secrets.json means
        // its secrets moved into the keychain, and copying an old one back would overwrite them with stale values.
        guard !fm.fileExists(atPath: store.path) else { return }
        let candidates = [legacyContainer, FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]]
        for source in candidates where source.path != directory.path {
            if !fm.fileExists(atPath: store.path) {
                let legacyStore = source.appendingPathComponent("default.store")
                if fm.fileExists(atPath: legacyStore.path) {
                    for suffix in ["", "-shm", "-wal"] {
                        let from = source.appendingPathComponent("default.store" + suffix)
                        let to = directory.appendingPathComponent("SwiftPulse.store" + suffix)
                        if fm.fileExists(atPath: from.path) { try? fm.copyItem(at: from, to: to) }
                    }
                }
            }
            if !fm.fileExists(atPath: secrets.path) {
                for name in ["secrets.json", "secrets.debug.json"] {
                    let from = source.appendingPathComponent(name)
                    if fm.fileExists(atPath: from.path) {
                        try? fm.copyItem(at: from, to: secrets)
                        break
                    }
                }
            }
        }
    }
}
