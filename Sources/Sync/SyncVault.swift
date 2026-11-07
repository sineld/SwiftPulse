import Foundation
import SwiftData

/// Cleartext header of a vault file: enough to show what is in the folder without asking for the passphrase.
struct VaultEnvelope: Codable {
    static let format = "swiftpulse.vault"
    var format = VaultEnvelope.format
    var version = 1
    var exportedAt = Date()
    var device = SyncVault.deviceName
    var app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    var kdf = "pbkdf2-sha256"
    var iterations = VaultCrypto.iterations
    var salt = Data()
    var payload = Data()
}

/// Everything worth carrying between machines: resources, their secrets and the app settings.
/// Session history is deliberately left out — it is per-device noise.
struct SyncVault: Codable {
    var machines: [MachineDTO] = []
    var groups: [GroupDTO] = []
    var identities: [IdentityDTO] = []
    var sshKeys: [SSHKeyDTO] = []
    var proxies: [ProxyDTO] = []
    var packages: [PackageDTO] = []
    var snippets: [SnippetDTO] = []
    var forwardingRules: [ForwardingDTO] = []
    var knownHosts: [KnownHostDTO] = []
    var settings: [String: SettingValue] = [:]
    var secrets: [String: String] = [:]
    /// What was deleted, "kind:uuid" → when (see `SyncTombstones`). Optional, like everything added later: older
    /// vaults decode without it, and older builds ignore it.
    var deleted: [String: Date]?
    var activity: [ActivityDTO]?

    enum Strategy: String, CaseIterable, Identifiable {
        case merge, replace
        var id: String { rawValue }
        var title: String { self == .merge ? "Merge" : "Replace" }
        var detail: String {
            self == .merge
                ? "Add what is missing, update what changed, and remove what was deleted on another Mac. Nothing else local is deleted."
                : "Delete every local machine, identity, key, proxy, snippet and rule first, then import the vault."
        }
    }

    struct Summary: Equatable {
        var inserted = 0, updated = 0, deleted = 0, secrets = 0
        var isEmpty: Bool { inserted == 0 && updated == 0 && deleted == 0 }
    }

    static var deviceName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    /// Tests point this at a scratch suite so they never overwrite the real preferences.
    static var defaults: UserDefaults = .standard

    var counts: [(String, Int)] {
        [("Machines", machines.count), ("Groups", groups.count), ("Identities", identities.count),
         ("SSH Keys", sshKeys.count), ("Proxies", proxies.count), ("Snippets", snippets.count),
         ("Packages", packages.count), ("Port Forwarding", forwardingRules.count),
         ("Known Hosts", knownHosts.count), ("Secrets", secrets.count)]
    }

    // MARK: - DTOs

    struct MachineDTO: Codable {
        var id: UUID, name: String, host: String, port: Int
        var authMethod: AuthMethod, identityID: UUID?, username: String, sshKeyID: UUID?, proxyID: UUID?
        var useJumpHost: Bool, jumpHostIDs: [UUID], connection: ConnectionKind, groupID: UUID?
        var tags: [String], showInDashboard: Bool, defaultSFTPPath: String, remark: String, createdAt: Date
        /// Optional so vaults from before they existed still decode.
        var hiddenFromAgents: Bool?
        var proxyCommand: String?
    }
    struct GroupDTO: Codable { var id: UUID, name: String, remark: String, createdAt: Date }
    struct IdentityDTO: Codable {
        var id: UUID, name: String, username: String, hasPassword: Bool, sshKeyID: UUID?, remark: String, createdAt: Date
    }
    struct SSHKeyDTO: Codable {
        var id: UUID, name: String, keyType: SSHKeyType, publicKey: String, hasPassphrase: Bool, remark: String, createdAt: Date
    }
    struct ProxyDTO: Codable {
        var id: UUID, name: String, host: String, port: Int, kind: ProxyKind, auth: ProxyAuth
        var username: String, remark: String, createdAt: Date
    }
    struct PackageDTO: Codable { var id: UUID, name: String, remark: String, createdAt: Date }
    struct SnippetDTO: Codable { var id: UUID, name: String, script: String, packageID: UUID?, remark: String, createdAt: Date }
    struct ForwardingDTO: Codable {
        var id: UUID, name: String, mode: ForwardingMode, machineID: UUID?, proxyID: UUID?
        var localHost: String, localPort: Int, targetHost: String, targetPort: Int
        var autoStart: Bool, remark: String, createdAt: Date
    }
    struct KnownHostDTO: Codable { var host: String, port: Int, keyType: String, publicKeyBase64: String, addedAt: Date }

    enum SettingValue: Codable, Equatable {
        case bool(Bool), int(Int), double(Double), string(String)
    }

    /// Settings that describe the user's preferences (not per-device state like the sync folder itself).
    static let settingKeys: [String: SettingKind] = [
        "connectionTimeout": .int, "alwaysTrustHostKeys": .bool, "requireAuthentication": .bool,
        "terminalBell": .bool, "suggestPortForwarding": .bool, "keepAlive": .bool, "keepAliveInterval": .int,
        "sftpKeepAlive": .bool, "snippetTimeout": .int, "dockerRefreshInterval": .int,
        "dashboardRefreshInterval": .int, "showTagFilters": .bool, "showServerListTags": .bool,
        "showLatency": .bool, "colorizeLatency": .bool, "reduceAnimations": .bool,
        "temperatureUnit": .string, "networkAsBits": .bool, "hideIPInformation": .bool,
        "terminalTheme": .string, "terminalFontName": .string, "terminalFontSize": .double,
        "terminalCursor": .string, "terminalCursorBlink": .bool, "colorScheme": .string, "showMenuBarMonitor": .bool,
        "terminalShellIntegration": .bool,
    ]
    enum SettingKind { case bool, int, double, string }

    // MARK: - export

    @MainActor
    static func build(from context: ModelContext) throws -> SyncVault {
        var vault = SyncVault()
        SyncTombstones.merge([:]) // drops expired tombstones
        let stones = SyncTombstones.tombstones
        vault.deleted = stones.isEmpty ? nil : stones
        let activity = try activity(in: context)
        vault.activity = activity.isEmpty ? nil : activity
        let keys = try context.fetch(FetchDescriptor<SSHKey>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let identities = try context.fetch(FetchDescriptor<Identity>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let proxies = try context.fetch(FetchDescriptor<Proxy>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let groups = try context.fetch(FetchDescriptor<MachineGroup>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let machines = try context.fetch(FetchDescriptor<Machine>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let packages = try context.fetch(FetchDescriptor<SnippetPackage>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let snippets = try context.fetch(FetchDescriptor<Snippet>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let rules = try context.fetch(FetchDescriptor<PortForwardingRule>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let hosts = try context.fetch(FetchDescriptor<KnownHostKey>())
            .sorted { ($0.host, $0.port, $0.publicKeyBase64) < ($1.host, $1.port, $1.publicKeyBase64) }

        vault.sshKeys = keys.map { .init(id: $0.id, name: $0.name, keyType: $0.keyType, publicKey: $0.publicKey,
                                         hasPassphrase: $0.hasPassphrase, remark: $0.remark, createdAt: $0.createdAt) }
        vault.identities = identities.map { .init(id: $0.id, name: $0.name, username: $0.username, hasPassword: $0.hasPassword,
                                                  sshKeyID: $0.sshKey?.id, remark: $0.remark, createdAt: $0.createdAt) }
        vault.proxies = proxies.map { .init(id: $0.id, name: $0.name, host: $0.host, port: $0.port, kind: $0.kind,
                                            auth: $0.auth, username: $0.username, remark: $0.remark, createdAt: $0.createdAt) }
        vault.groups = groups.map { .init(id: $0.id, name: $0.name, remark: $0.remark, createdAt: $0.createdAt) }
        vault.machines = machines.map { .init(id: $0.id, name: $0.name, host: $0.host, port: $0.port,
                                              authMethod: $0.authMethod, identityID: $0.identity?.id, username: $0.username,
                                              sshKeyID: $0.sshKey?.id, proxyID: $0.proxy?.id, useJumpHost: $0.useJumpHost,
                                              jumpHostIDs: $0.jumpHostIDs, connection: $0.connection, groupID: $0.group?.id,
                                              tags: $0.tags, showInDashboard: $0.showInDashboard,
                                              defaultSFTPPath: $0.defaultSFTPPath, remark: $0.remark, createdAt: $0.createdAt,
                                              hiddenFromAgents: $0.hiddenFromAgents, proxyCommand: $0.proxyCommand.nilIfEmpty) }
        vault.packages = packages.map { .init(id: $0.id, name: $0.name, remark: $0.remark, createdAt: $0.createdAt) }
        vault.snippets = snippets.map { .init(id: $0.id, name: $0.name, script: $0.script, packageID: $0.package?.id,
                                              remark: $0.remark, createdAt: $0.createdAt) }
        vault.forwardingRules = rules.map { .init(id: $0.id, name: $0.name, mode: $0.mode, machineID: $0.machineID,
                                                  proxyID: $0.proxyID, localHost: $0.localHost, localPort: $0.localPort,
                                                  targetHost: $0.targetHost, targetPort: $0.targetPort,
                                                  autoStart: $0.autoStart, remark: $0.remark, createdAt: $0.createdAt) }
        vault.knownHosts = hosts.map { .init(host: $0.host, port: $0.port, keyType: $0.keyType,
                                             publicKeyBase64: $0.publicKeyBase64, addedAt: $0.addedAt) }

        var secretKeys: [String] = machines.map(\.passwordKey) + identities.map(\.passwordKey) + proxies.map(\.passwordKey)
        secretKeys += keys.flatMap { [$0.privateKeyKey, $0.passphraseKey] }
        for key in secretKeys {
            if let value = KeychainService.get(key), !value.isEmpty { vault.secrets[key] = value }
        }

        let defaults = SyncVault.defaults
        for (key, kind) in settingKeys {
            guard defaults.object(forKey: key) != nil else { continue }
            switch kind {
            case .bool: vault.settings[key] = .bool(defaults.bool(forKey: key))
            case .int: vault.settings[key] = .int(defaults.integer(forKey: key))
            case .double: vault.settings[key] = .double(defaults.double(forKey: key))
            case .string: vault.settings[key] = .string(defaults.string(forKey: key) ?? "")
            }
        }
        return vault
    }

    // MARK: - import

    @MainActor
    @discardableResult
    static func apply(_ vault: SyncVault, to context: ModelContext, strategy: Strategy) throws -> Summary {
        var summary = Summary()
        SyncTombstones.merge(vault.deleted ?? [:])
        SyncTombstones.suppressed = true // removing what the vault says is not a deletion of the user's own
        defer { SyncTombstones.suppressed = false }

        var keys = try context.fetch(FetchDescriptor<SSHKey>())
        var identities = try context.fetch(FetchDescriptor<Identity>())
        var proxies = try context.fetch(FetchDescriptor<Proxy>())
        var groups = try context.fetch(FetchDescriptor<MachineGroup>())
        var machines = try context.fetch(FetchDescriptor<Machine>())
        var packages = try context.fetch(FetchDescriptor<SnippetPackage>())
        var snippets = try context.fetch(FetchDescriptor<Snippet>())
        var rules = try context.fetch(FetchDescriptor<PortForwardingRule>())
        var hosts = try context.fetch(FetchDescriptor<KnownHostKey>())

        if strategy == .replace {
            let incoming = Set(vault.secrets.keys)
            var stale = machines.map(\.passwordKey) + identities.map(\.passwordKey) + proxies.map(\.passwordKey)
            stale += keys.flatMap { [$0.privateKeyKey, $0.passphraseKey] }
            for key in stale where !incoming.contains(key) { KeychainService.delete(key) }

            summary.deleted = machines.count + identities.count + keys.count + proxies.count
                + groups.count + packages.count + snippets.count + rules.count + hosts.count
            machines.forEach(context.delete); identities.forEach(context.delete); keys.forEach(context.delete)
            proxies.forEach(context.delete); groups.forEach(context.delete); packages.forEach(context.delete)
            snippets.forEach(context.delete); rules.forEach(context.delete); hosts.forEach(context.delete)
            machines = []; identities = []; keys = []; proxies = []; groups = []; packages = []; snippets = []; rules = []; hosts = []
        }

        // Deletions made on other Macs: remove those items here, and never re-add them from a vault that predates them.
        let stones = SyncTombstones.tombstones
        let deletedIDs = Set(stones.keys.compactMap { $0.split(separator: ":").last.map(String.init) })
        func gone(_ kind: String, _ id: UUID) -> Bool { stones[SyncTombstones.key(kind, id)] != nil }
        func purge<T: PersistentModel>(_ list: inout [T], _ kind: String, _ secrets: (T) -> [String] = { _ in [] }) where T.ID == UUID {
            for item in list where gone(kind, item.id) {
                secrets(item).forEach { KeychainService.delete($0) }
                context.delete(item)
                summary.deleted += 1
            }
            list.removeAll { gone(kind, $0.id) }
        }
        purge(&rules, "rule"); purge(&snippets, "snippet"); purge(&machines, "machine") { [$0.passwordKey] }
        purge(&identities, "identity") { [$0.passwordKey] }; purge(&keys, "sshKey") { [$0.privateKeyKey, $0.passphraseKey] }
        purge(&proxies, "proxy") { [$0.passwordKey] }; purge(&groups, "group"); purge(&packages, "package")

        var keyByID = Dictionary(keys.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var identityByID = Dictionary(identities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var proxyByID = Dictionary(proxies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groupByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var machineByID = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var packageByID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snippetByID = Dictionary(snippets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ruleByID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        /// Returns the existing row for this id or inserts a new one, counting the outcome.
        func resolve<T: PersistentModel>(_ id: UUID, _ index: inout [UUID: T], _ make: () -> T) -> T {
            if let existing = index[id] {
                summary.updated += 1
                return existing
            }
            let created = make()
            context.insert(created)
            index[id] = created
            summary.inserted += 1
            return created
        }

        for dto in vault.sshKeys where !gone("sshKey", dto.id) {
            let model = resolve(dto.id, &keyByID) { let created = SSHKey(); created.id = dto.id; return created }
            model.name = dto.name; model.keyType = dto.keyType; model.publicKey = dto.publicKey
            model.hasPassphrase = dto.hasPassphrase; model.remark = dto.remark; model.createdAt = dto.createdAt
        }
        for dto in vault.identities where !gone("identity", dto.id) {
            let model = resolve(dto.id, &identityByID) { let created = Identity(); created.id = dto.id; return created }
            model.name = dto.name; model.username = dto.username; model.hasPassword = dto.hasPassword
            model.sshKey = dto.sshKeyID.flatMap { keyByID[$0] }
            model.remark = dto.remark; model.createdAt = dto.createdAt
        }
        for dto in vault.proxies where !gone("proxy", dto.id) {
            let model = resolve(dto.id, &proxyByID) { let created = Proxy(); created.id = dto.id; return created }
            model.name = dto.name; model.host = dto.host; model.port = dto.port; model.kind = dto.kind
            model.auth = dto.auth; model.username = dto.username; model.remark = dto.remark; model.createdAt = dto.createdAt
        }
        for dto in vault.groups where !gone("group", dto.id) {
            let model = resolve(dto.id, &groupByID) { let created = MachineGroup(); created.id = dto.id; return created }
            model.name = dto.name; model.remark = dto.remark; model.createdAt = dto.createdAt
        }
        for dto in vault.machines where !gone("machine", dto.id) {
            let model = resolve(dto.id, &machineByID) { let created = Machine(); created.id = dto.id; return created }
            model.name = dto.name; model.host = dto.host; model.port = dto.port
            model.authMethod = dto.authMethod
            model.identity = dto.identityID.flatMap { identityByID[$0] }
            model.username = dto.username
            model.sshKey = dto.sshKeyID.flatMap { keyByID[$0] }
            model.proxy = dto.proxyID.flatMap { proxyByID[$0] }
            model.useJumpHost = dto.useJumpHost; model.jumpHostIDs = dto.jumpHostIDs
            model.connection = dto.connection
            model.group = dto.groupID.flatMap { groupByID[$0] }
            model.tags = dto.tags; model.showInDashboard = dto.showInDashboard; model.hiddenFromAgents = dto.hiddenFromAgents ?? false
            model.proxyCommand = dto.proxyCommand ?? ""
            model.defaultSFTPPath = dto.defaultSFTPPath; model.remark = dto.remark; model.createdAt = dto.createdAt
        }
        for dto in vault.packages where !gone("package", dto.id) {
            let model = resolve(dto.id, &packageByID) { let created = SnippetPackage(); created.id = dto.id; return created }
            model.name = dto.name; model.remark = dto.remark; model.createdAt = dto.createdAt
        }
        for dto in vault.snippets where !gone("snippet", dto.id) {
            let model = resolve(dto.id, &snippetByID) { let created = Snippet(); created.id = dto.id; return created }
            model.name = dto.name; model.script = dto.script
            model.package = dto.packageID.flatMap { packageByID[$0] }
            model.remark = dto.remark; model.createdAt = dto.createdAt
        }
        for dto in vault.forwardingRules where !gone("rule", dto.id) {
            let model = resolve(dto.id, &ruleByID) { let created = PortForwardingRule(); created.id = dto.id; return created }
            model.name = dto.name; model.mode = dto.mode; model.machineID = dto.machineID; model.proxyID = dto.proxyID
            model.localHost = dto.localHost; model.localPort = dto.localPort
            model.targetHost = dto.targetHost; model.targetPort = dto.targetPort
            model.autoStart = dto.autoStart; model.remark = dto.remark; model.createdAt = dto.createdAt
        }
        for dto in vault.knownHosts {
            let existing = hosts.first { $0.host == dto.host && $0.port == dto.port && $0.publicKeyBase64 == dto.publicKeyBase64 }
            if existing == nil {
                let created = KnownHostKey(host: dto.host, port: dto.port, keyType: dto.keyType, publicKeyBase64: dto.publicKeyBase64)
                created.addedAt = dto.addedAt
                context.insert(created)
                hosts.append(created)
                summary.inserted += 1
            }
        }

        // Secret keys end in their owner's uuid ("machine.password.<uuid>"); a deleted owner's secret stays gone.
        let secrets = vault.secrets.filter { !deletedIDs.contains(String($0.key.split(separator: ".").last ?? "")) }
        for (key, value) in secrets { KeychainService.set(value, for: key) }
        summary.secrets = secrets.count
        if let activity = vault.activity { try applyActivity(activity, to: context) }

        let defaults = SyncVault.defaults
        for (key, value) in vault.settings {
            switch value {
            case .bool(let v): defaults.set(v, forKey: key)
            case .int(let v): defaults.set(v, forKey: key)
            case .double(let v): defaults.set(v, forKey: key)
            case .string(let v): defaults.set(v, forKey: key)
            }
        }

        try context.save()
        return summary
    }

    // MARK: - file format

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys keep the encoding deterministic, so the export fingerprint only changes when the
        // data actually changes (SwiftData fetches come back in an arbitrary order otherwise).
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func fileData(passphrase: String) throws -> Data {
        let plaintext = try SyncVault.encoder().encode(self)
        let sealed = try VaultCrypto.seal(plaintext, passphrase: passphrase)
        var envelope = VaultEnvelope()
        envelope.salt = sealed.salt
        envelope.payload = sealed.payload
        return try SyncVault.encoder().encode(envelope)
    }

    enum VaultError: LocalizedError, Equatable {
        case unsupportedFormat(String)
        var errorDescription: String? {
            if case .unsupportedFormat(let found) = self { "Not a SwiftPulse vault file (found “\(found)”)." } else { nil }
        }
    }

    static func envelope(from data: Data) throws -> VaultEnvelope {
        let envelope = try decoder().decode(VaultEnvelope.self, from: data)
        guard envelope.format == VaultEnvelope.format else { throw VaultError.unsupportedFormat(envelope.format) }
        return envelope
    }

    static func read(_ data: Data, passphrase: String) throws -> (SyncVault, VaultEnvelope) {
        let envelope = try envelope(from: data)
        let plaintext = try VaultCrypto.open(payload: envelope.payload, salt: envelope.salt,
                                             passphrase: passphrase, iterations: envelope.iterations)
        return (try decoder().decode(SyncVault.self, from: plaintext), envelope)
    }
}
