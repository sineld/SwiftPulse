import Foundation
import SwiftData

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Machine.self, MachineGroup.self, Identity.self, SSHKey.self, Proxy.self,
        SnippetPackage.self, Snippet.self, PortForwardingRule.self,
        SessionRecord.self, KnownHostKey.self, AgentActivity.self,
    ]

    static func container(inMemory: Bool = false) -> ModelContainer {
        if !inMemory {
            AppPaths.migrateLegacyDataIfNeeded()
            AppPaths.migrateLegacyPreferencesIfNeeded()
        }
        let config = inMemory ? ModelConfiguration(isStoredInMemoryOnly: true) : ModelConfiguration(url: AppPaths.store)
        do {
            return try ModelContainer(for: Schema(models), configurations: [config])
        } catch {
            fatalError("ModelContainer failed: \(error)")
        }
    }
}
