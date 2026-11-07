import Foundation

/// A throwaway preferences domain for one test. Its suite name is a path in a temporary folder, so the plist lives
/// there instead of in ~/Library/Preferences (where `removePersistentDomain` would still leave an empty file behind
/// on every run), and `discard` simply deletes the folder.
enum TestDefaults {
    static func make() -> (name: String, defaults: UserDefaults) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpulse-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = folder.appendingPathComponent("prefs").path
        return (name, UserDefaults(suiteName: name)!)
    }

    static func discard(_ name: String) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: name).deletingLastPathComponent())
    }
}
