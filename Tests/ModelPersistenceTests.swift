import Foundation
import SwiftData
import Testing
@testable import SwiftPulse

/// Values must survive a save and a fresh fetch. Before macOS 27, SwiftData stores through Core Data, where a property
/// named like an NSManagedObject member (`updated`, `deleted`, `inserted`…) reads back as that member instead.
@MainActor
struct ModelPersistenceTests {
    @Test func activityDatesSurviveASaveAndAFreshContext() throws {
        let container = AppSchema.container(inMemory: true)
        let writer = ModelContext(container)
        let entry = AgentActivity(client: "claude-code", tool: "run_command", hostIDs: ["h"], hostNames: ["web"],
                                  summary: "Run on 1 machine", detail: "uptime", outcome: "exit 0 on 1")
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        entry.lastUpdated = when
        writer.insert(entry)
        try writer.save()

        let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<AgentActivity>()).first)
        #expect(fetched.lastUpdated == when)
        #expect(fetched.date.timeIntervalSinceReferenceDate > 0)
    }
}
