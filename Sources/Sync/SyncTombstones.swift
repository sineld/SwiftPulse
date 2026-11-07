import Foundation
import SwiftData

/// Carries deletions between Macs. Each deletion of a synced item is recorded as it is saved, as a tombstone
/// ("kind:uuid" → when) that travels in the vault, deletes the item on the other Macs, and keeps a vault that
/// hasn't seen the deletion yet from bringing it back. Tombstones are kept for 180 days.
///
/// Recorded at the moment of deletion rather than inferred from what is missing, so a store that is reset or
/// recreated never reads as "the user deleted everything" and wipes the other Macs.
@MainActor
enum SyncTombstones {
    static let tombstonesKey = "syncTombstones"
    static let lifetime: TimeInterval = 180 * 86400
    /// Set while an import applies a vault: what Replace removes was not deleted by the user.
    static var suppressed = false
    private static var observer: NSObjectProtocol?

    static func key(_ kind: String, _ id: UUID) -> String { "\(kind):\(id.uuidString)" }

    /// The tombstone key of a synced model, nil for anything else.
    static func key(of model: any PersistentModel) -> String? {
        switch model {
        case let m as Machine: key("machine", m.id)
        case let m as MachineGroup: key("group", m.id)
        case let m as Identity: key("identity", m.id)
        case let m as SSHKey: key("sshKey", m.id)
        case let m as Proxy: key("proxy", m.id)
        case let m as SnippetPackage: key("package", m.id)
        case let m as Snippet: key("snippet", m.id)
        case let m as PortForwardingRule: key("rule", m.id)
        default: nil
        }
    }

    static var tombstones: [String: Date] {
        get {
            let stored = SyncVault.defaults.dictionary(forKey: tombstonesKey) as? [String: Double] ?? [:]
            return stored.mapValues { Date(timeIntervalSince1970: $0) }
        }
        set { SyncVault.defaults.set(newValue.mapValues(\.timeIntervalSince1970), forKey: tombstonesKey) }
    }

    /// Watches every context's saves for deleted synced items. Called once at launch.
    static func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) { note in
            // In-memory stores (tests, previews) are never synced.
            guard let context = note.object as? ModelContext,
                  context.container.configurations.contains(where: { !$0.isStoredInMemoryOnly }) else { return }
            MainActor.assumeIsolated { record(context.deletedModelsArray) }
        }
    }

    static func record(_ deleted: [any PersistentModel], now: Date = Date()) {
        guard !suppressed else { return }
        let keys = deleted.compactMap(key(of:))
        guard !keys.isEmpty else { return }
        var stones = tombstones
        for key in keys where stones[key] == nil { stones[key] = now }
        tombstones = stones
    }

    /// Adds another Mac's tombstones to this one's, keeping the earlier date of each, and drops expired ones.
    static func merge(_ incoming: [String: Date], now: Date = Date()) {
        tombstones = tombstones.merging(incoming) { min($0, $1) }.filter { now.timeIntervalSince($0.value) < lifetime }
    }
}

/// Agent activity in the vault: recent entries only, newest version of each wins.
extension SyncVault {
    struct ActivityDTO: Codable, Equatable {
        var id: UUID, date: Date, updated: Date, device: String, client: String, tool: String
        var hostIDs: [String], hostNames: [String], summary: String, detail: String, outcome: String
        var results: [AgentActivity.Result], task: String?, steps: [AgentActivity.Step]
    }

    static let activityAge: TimeInterval = 90 * 86400
    static let activityLimit = 1000
    /// When this Mac's activity was last cleared: older entries from other Macs don't come back.
    static let activityClearedKey = "agentActivityClearedAt"

    @MainActor
    static func activity(in context: ModelContext, now: Date = Date()) throws -> [ActivityDTO] {
        let cutoff = now.addingTimeInterval(-activityAge)
        var recent = FetchDescriptor<AgentActivity>(predicate: #Predicate { $0.lastUpdated > cutoff },
                                                    sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)])
        recent.fetchLimit = activityLimit
        return try context.fetch(recent).sorted { $0.id.uuidString < $1.id.uuidString }.map {
            ActivityDTO(id: $0.id, date: $0.date, updated: $0.lastUpdated, device: $0.device, client: $0.client, tool: $0.tool,
                        hostIDs: $0.hostIDs, hostNames: $0.hostNames, summary: $0.summary, detail: $0.detail,
                        outcome: $0.outcome, results: $0.results, task: $0.task, steps: $0.steps)
        }
    }

    @MainActor
    static func applyActivity(_ incoming: [ActivityDTO], to context: ModelContext) throws {
        let cleared = defaults.object(forKey: activityClearedKey) as? Date ?? .distantPast
        let local = Dictionary(try context.fetch(FetchDescriptor<AgentActivity>()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for dto in incoming where dto.updated > cleared {
            let model: AgentActivity
            if let existing = local[dto.id] {
                guard dto.updated > existing.lastUpdated else { continue }
                model = existing
            } else {
                model = AgentActivity(client: dto.client, tool: dto.tool, hostIDs: [], hostNames: [], summary: "", detail: "", outcome: "")
                model.id = dto.id
                context.insert(model)
            }
            model.date = dto.date; model.lastUpdated = dto.updated; model.device = dto.device; model.client = dto.client
            model.tool = dto.tool; model.hostIDs = dto.hostIDs; model.hostNames = dto.hostNames; model.summary = dto.summary
            model.detail = dto.detail; model.outcome = dto.outcome; model.results = dto.results; model.task = dto.task
            model.steps = dto.steps
        }
    }
}
