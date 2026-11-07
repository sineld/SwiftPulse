import Testing
import Foundation
import SwiftData
@testable import SwiftPulse

/// Deletions and agent activity travelling between two Macs, each with its own store and preferences.
// Nested so it never runs alongside the other suites that swap shared test hooks.
extension SharedStateTests {
@MainActor @Suite(.serialized)
struct SyncDeletionTests {
    private func withScratch(_ body: () throws -> Void) rethrows {
        let (suite, defaults) = TestDefaults.make()
        let secrets = FileManager.default.temporaryDirectory.appendingPathComponent("sync-deletion-\(UUID().uuidString).json")
        SyncVault.defaults = defaults
        KeychainService.overrideStoreURL = secrets
        defer {
            TestDefaults.discard(suite)
            SyncVault.defaults = .standard
            KeychainService.overrideStoreURL = nil
            try? FileManager.default.removeItem(at: secrets)
        }
        try body()
    }

    private func store() -> ModelContext { ModelContext(AppSchema.container(inMemory: true)) }

    @Test func aDeletionTravelsAndAnOlderVaultCantBringItBack() throws {
        try withScratch {
            // Both Macs have the machine.
            let a = store(), b = store()
            let machine = Machine(name: "old-box", host: "10.0.0.5")
            a.insert(machine)
            try a.save()
            KeychainService.set("pw", for: machine.passwordKey)
            let before = try SyncVault.build(from: a)
            try SyncVault.apply(before, to: b, strategy: .merge)
            #expect(try b.fetchCount(FetchDescriptor<Machine>()) == 1)

            // Mac A deletes it (what the save observer records), exports, and Mac B merges that.
            SyncTombstones.record([machine])
            a.delete(machine)
            try a.save()
            let after = try SyncVault.build(from: a)
            #expect(after.deleted?.keys.contains(SyncTombstones.key("machine", machine.id)) == true)
            let summary = try SyncVault.apply(after, to: b, strategy: .merge)
            #expect(summary.deleted == 1)
            #expect(try b.fetchCount(FetchDescriptor<Machine>()) == 0)
            #expect(KeychainService.get(machine.passwordKey) == nil)

            // A third Mac's vault from before the deletion still has it, and its password: neither comes back.
            try SyncVault.apply(before, to: b, strategy: .merge)
            #expect(try b.fetchCount(FetchDescriptor<Machine>()) == 0)
            #expect(KeychainService.get(machine.passwordKey) == nil)
        }
    }

    @Test func theSaveObserverRecordsDeletionsInOnDiskStores() throws {
        try withScratch {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-observer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let container = try ModelContainer(for: Schema(AppSchema.models),
                                               configurations: [ModelConfiguration(url: folder.appendingPathComponent("t.store"))])
            let context = ModelContext(container)
            let snippet = Snippet(name: "gone")
            context.insert(snippet)
            try context.save()
            SyncTombstones.observe()

            context.delete(snippet)
            try context.save()
            #expect(SyncTombstones.tombstones[SyncTombstones.key("snippet", snippet.id)] != nil)

            // In-memory stores are ignored.
            let memory = store()
            let other = Snippet(name: "scratch")
            memory.insert(other)
            try memory.save()
            memory.delete(other)
            try memory.save()
            #expect(SyncTombstones.tombstones[SyncTombstones.key("snippet", other.id)] == nil)
        }
    }

    @Test func importsAndExpiredTombstonesDontCount() throws {
        try withScratch {
            SyncTombstones.suppressed = true
            SyncTombstones.record([Machine()])
            SyncTombstones.suppressed = false
            #expect(SyncTombstones.tombstones.isEmpty) // what an import removes is not the user's deletion

            let old = Machine(), recent = Machine()
            SyncTombstones.record([old], now: Date().addingTimeInterval(-200 * 86400))
            SyncTombstones.record([recent, Snippet(), SessionRecord(kind: .terminal, machine: recent, username: "")])
            SyncTombstones.merge([:])
            let keys = SyncTombstones.tombstones.keys
            #expect(keys.contains(SyncTombstones.key("machine", recent.id)))
            #expect(!keys.contains(SyncTombstones.key("machine", old.id))) // expired
            #expect(keys.count == 2) // the machine and the snippet; session records don't sync
        }
    }

    @Test func activityMergesNewestFirstAndRespectsAClear() throws {
        try withScratch {
            let a = store(), b = store()
            let entry = AgentActivity(client: "claude-code", tool: "run_command", hostIDs: ["h"], hostNames: ["web"],
                                      summary: "Run on 1 machine", detail: "uptime", outcome: "exit 0 on 1")
            a.insert(entry)
            try a.save()
            try SyncVault.apply(try SyncVault.build(from: a), to: b, strategy: .merge)
            #expect(try b.fetch(FetchDescriptor<AgentActivity>()).first?.detail == "uptime")

            entry.outcome = "exit 1 on 1"
            entry.lastUpdated = Date().addingTimeInterval(5)
            try a.save()
            try SyncVault.apply(try SyncVault.build(from: a), to: b, strategy: .merge)
            #expect(try b.fetch(FetchDescriptor<AgentActivity>()).map(\.outcome) == ["exit 1 on 1"])

            // B clears its log; A's copy doesn't come back.
            try b.fetch(FetchDescriptor<AgentActivity>()).forEach(b.delete)
            SyncVault.defaults.set(Date().addingTimeInterval(10), forKey: SyncVault.activityClearedKey)
            try SyncVault.apply(try SyncVault.build(from: a), to: b, strategy: .merge)
            #expect(try b.fetchCount(FetchDescriptor<AgentActivity>()) == 0)
        }
    }
}
}
