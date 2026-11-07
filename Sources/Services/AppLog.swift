import Foundation

/// In-app ring buffer of diagnostic messages shown in Settings > Logs. `debugLog` feeds it.
@Observable
final class AppLog: @unchecked Sendable {
    struct Entry: Identifiable { let id = UUID(); let time = Date(); let message: String }
    static let shared = AppLog()
    private(set) var entries: [Entry] = []
    private let lock = NSLock()

    func add(_ message: String) {
        lock.withLock {
            entries.append(Entry(message: message))
            if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        }
    }
}
