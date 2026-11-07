import Foundation
import SwiftData

/// What agents did, machine by machine: every run and change through the MCP server (approved, declined or
/// failed), and what agents report doing over their own connections (`log_activity`). The next agent reads it
/// with `get_activity`. Never holds a secret: commands are what the agent sent, and output is a short tail.
///
/// An agent names the task a step serves ("Install nginx"); later steps toward the same task go into the same
/// entry, so it reads as what was done, with the steps under it.
@Model
final class AgentActivity {
    struct Result: Codable, Equatable, Sendable {
        var host: String
        var exitCode: Int?
        var tail: String
    }

    struct Step: Codable, Equatable, Sendable {
        var date: Date
        var tool: String
        var summary: String
        var detail: String
        var outcome: String
        var results: [Result]
    }

    var id: UUID = UUID()
    var date: Date = Date()
    /// When the last step was added. Not named `updated`: before macOS 27 SwiftData runs on Core Data, where that
    /// name is NSManagedObject's own `isUpdated` flag, so the date never reached the store and always read back as 2001.
    @Attribute(originalName: "updated") var lastUpdated: Date = Date()
    /// The Mac it happened on.
    var device: String = ""
    /// The MCP client ("claude-code", "codex"…).
    var client: String = ""
    /// The tool, or "report" for what an agent says it did itself.
    var tool: String = ""
    var hostIDs: [String] = []
    var hostNames: [String] = []
    /// One line: "Run on 3 machines", "Add machine web-2", or the task when there is one.
    var summary: String = ""
    var detail: String = ""
    /// "ok", "declined", an error, or "exit 0 on 3, exit 1 on 1".
    var outcome: String = ""
    var results: [Result] = []
    var task: String?
    var steps: [Step] = []

    init(client: String, tool: String, hostIDs: [String], hostNames: [String], summary: String, detail: String,
         outcome: String, results: [Result] = []) {
        self.device = Host.current().localizedName ?? "Mac"
        self.client = client
        self.tool = tool
        self.hostIDs = hostIDs
        self.hostNames = hostNames
        self.summary = summary
        self.detail = detail
        self.outcome = outcome
        self.results = results
    }

    var asStep: Step { Step(date: date, tool: tool, summary: summary, detail: detail, outcome: outcome, results: results) }
}

/// Adds entries, folding a task's steps together, and keeps the log to a bounded size.
@MainActor
enum AgentActivityLog {
    /// A step joins its task's entry when the entry changed less than this long ago.
    static let taskGap: TimeInterval = 3 * 3600
    static let stepLimit = 100
    static let limit = 5000

    static func add(_ entry: AgentActivity, task: String?, in context: ModelContext) {
        let task = task?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let task, let existing = openEntry(task: task, client: entry.client, in: context) {
            if existing.steps.count < stepLimit { existing.steps.append(entry.asStep) }
            for (id, name) in zip(entry.hostIDs, entry.hostNames) where !existing.hostIDs.contains(id) {
                existing.hostIDs.append(id)
                existing.hostNames.append(name)
            }
            existing.outcome = entry.outcome
            existing.lastUpdated = Date()
        } else {
            if let task {
                entry.task = task
                entry.steps = [entry.asStep]
                entry.summary = task
            }
            context.insert(entry)
        }
        trim(in: context)
        try? context.save()
    }

    /// The newest entry for this task and client that is still open.
    private static func openEntry(task: String, client: String, in context: ModelContext) -> AgentActivity? {
        let cutoff = Date().addingTimeInterval(-taskGap)
        var descriptor = FetchDescriptor<AgentActivity>(predicate: #Predicate { $0.client == client && $0.lastUpdated > cutoff },
                                                        sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)])
        descriptor.fetchLimit = 20
        let recent = (try? context.fetch(descriptor)) ?? []
        return recent.first { $0.task?.caseInsensitiveCompare(task) == .orderedSame }
    }

    private static func trim(in context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<AgentActivity>())) ?? 0
        guard count > limit else { return }
        var oldest = FetchDescriptor<AgentActivity>(sortBy: [SortDescriptor(\.lastUpdated)])
        oldest.fetchLimit = count - limit
        ((try? context.fetch(oldest)) ?? []).forEach(context.delete)
    }

    /// Newest first; for one machine when `hostID` is given.
    static func entries(hostID: String?, limit: Int, in context: ModelContext) -> [AgentActivity] {
        let all = (try? context.fetch(FetchDescriptor<AgentActivity>(sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)]))) ?? []
        let filtered = hostID.map { id in all.filter { $0.hostIDs.contains(id) } } ?? all
        return Array(filtered.prefix(max(limit, 1)))
    }

    /// "exit 0 on 3, exit 1 on 1, failed on 1" for a run's results.
    static func outcome(of runs: [AgentRunResult]) -> String {
        let groups = Dictionary(grouping: runs) { $0.exitCode.map { "exit \($0)" } ?? "failed" }
        return groups.map { "\($0.key) on \($0.value.count)" }.sorted().joined(separator: ", ")
    }
}

/// An entry as an agent reads it.
struct AgentActivityRecord: Codable, Sendable {
    var id: String
    var date: Date
    var updated: Date
    var device: String
    var client: String
    var tool: String
    var hosts: [String]
    var summary: String
    var detail: String
    var outcome: String
    var task: String?
    var steps: [AgentActivity.Step]?
    var results: [AgentActivity.Result]?

    init(_ entry: AgentActivity) {
        id = entry.id.uuidString
        date = entry.date
        updated = entry.lastUpdated
        device = entry.device
        client = entry.client
        tool = entry.tool
        hosts = entry.hostNames
        summary = entry.summary
        detail = entry.task == nil ? entry.detail : ""
        outcome = entry.outcome
        task = entry.task
        steps = entry.task == nil ? nil : entry.steps
        results = entry.task == nil && !entry.results.isEmpty ? entry.results : nil
    }
}
