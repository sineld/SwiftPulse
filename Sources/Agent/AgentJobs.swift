import Foundation

/// A command running on machines in the background: `run_command` hands it off when the machines take longer
/// than the agent wanted to wait, and the agent follows it with `get_job` or stops it with `cancel_job`.
@MainActor
final class AgentJob {
    let id = UUID().uuidString.prefix(8).lowercased()
    let command: String
    let hosts: [String]
    let started = Date()
    /// Each machine's result as it finishes; in the machines' order once the job is done.
    var results: [AgentRunResult] = []
    var finished: Date?
    var cancelled = false
    var task: Task<Void, Never>?

    init(command: String, hosts: [String]) {
        self.command = command
        self.hosts = hosts
    }

    var isDone: Bool { finished != nil }

    var status: JSONValue {
        [
            "job": .string(id),
            "status": .string(cancelled ? "cancelled" : isDone ? "done" : "running"),
            "finished": .number(Double(results.count)), "total": .number(Double(hosts.count)),
            "seconds": .number((Date().timeIntervalSince(started) * 10).rounded() / 10),
            "results": .from(results),
        ]
    }
}

@MainActor
final class AgentJobs {
    /// Finished jobs stay readable this long.
    static let keep: TimeInterval = 3600
    private var jobs: [String: AgentJob] = [:]

    func add(_ job: AgentJob) {
        let now = Date()
        jobs = jobs.filter { $0.value.finished.map { now.timeIntervalSince($0) < Self.keep } ?? true }
        jobs[job.id] = job
    }

    func job(_ id: String) throws -> AgentJob {
        guard let job = jobs[id.lowercased()] else { throw AgentToolError("No job \(id); jobs are kept for an hour after they finish.") }
        return job
    }
}
