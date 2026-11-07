import Foundation
import SwiftData

/// Reads the user's `~/.ssh/config` the way OpenSSH does: every concrete `Host` alias (following `Include`), each
/// resolved by `ssh -G`, so defaults, `Match` blocks and wildcards apply exactly as they would for `ssh alias`.
enum SSHConfigImport {
    struct Entry: Identifiable, Equatable {
        var id: String { alias }
        var alias: String
        var hostname: String
        var port: Int
        var user: String
        /// The first identity file that exists on this Mac (explicit ones come first in `ssh -G`).
        var identityFile: String?
        /// Hops as written: aliases or `[user@]host[:port]`.
        var proxyJump: [String]
    }

    static var sshDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh") }

    /// `Host` aliases in config text, without patterns (`*`, `?`, `!`), and the `Include` arguments.
    static func parse(_ text: String) -> (aliases: [String], includes: [String]) {
        var aliases: [String] = [], includes: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let values = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            switch parts[0].lowercased() {
            case "host": aliases += values.filter { !$0.contains(where: "*?!".contains) }
            case "include": includes += values
            default: break
            }
        }
        return (aliases, includes)
    }

    /// Every alias in `~/.ssh/config` and the files it includes (relative paths are under ~/.ssh, globs expand).
    static func aliases(config: URL = sshDirectory.appendingPathComponent("config"), depth: Int = 0) -> [String] {
        guard depth < 8, let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        let (aliases, includes) = parse(text)
        var all = aliases
        for include in includes {
            let expanded = (include as NSString).expandingTildeInPath
            let pattern = expanded.hasPrefix("/") ? expanded : sshDirectory.appendingPathComponent(expanded).path
            for path in glob(pattern) { all += self.aliases(config: URL(fileURLWithPath: path), depth: depth + 1) }
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    private static func glob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
    }

    /// `ssh -G` output (lowercase keys, one per line) for an alias.
    static func entry(alias: String, sshG output: String, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Entry {
        var entry = Entry(alias: alias, hostname: alias, port: 22, user: NSUserName(), identityFile: nil, proxyJump: [])
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "hostname": entry.hostname = parts[1]
            case "port": entry.port = Int(parts[1]) ?? 22
            case "user": entry.user = parts[1]
            case "identityfile":
                let path = (parts[1] as NSString).expandingTildeInPath
                if entry.identityFile == nil, fileExists(path) { entry.identityFile = path }
            case "proxyjump" where parts[1] != "none": entry.proxyJump = parts[1].split(separator: ",").map(String.init)
            default: break
            }
        }
        return entry
    }

    /// Runs `ssh -G` for every alias in the config.
    static func load() async -> [Entry] {
        await withTaskGroup(of: Entry?.self) { group in
            for alias in aliases() {
                group.addTask {
                    guard let output = try? run("/usr/bin/ssh", ["-G", alias]) else { return nil }
                    return entry(alias: alias, sshG: output)
                }
            }
            var entries: [Entry] = []
            for await entry in group { if let entry { entries.append(entry) } }
            return entries.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
        }
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Import

    struct Outcome: Equatable { var added: [String] = [], skipped: [String] = [], notes: [String] = [] }

    /// Adds the entries as machines signing in with their own user and key. Keys are read once into the secret
    /// store (one SSH key per file); jump hosts resolve to machines imported with them or already in SwiftPulse.
    @MainActor
    static func importEntries(_ entries: [Entry], into context: ModelContext,
                              readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) throws -> Outcome {
        var outcome = Outcome()
        let existing = try context.fetch(FetchDescriptor<Machine>())
        var keys = try context.fetch(FetchDescriptor<SSHKey>())
        var byAlias: [String: Machine] = [:]

        for entry in entries {
            if existing.contains(where: { $0.host == entry.hostname && $0.port == entry.port && $0.username == entry.user }) {
                outcome.skipped.append(entry.alias)
                continue
            }
            let machine = Machine(name: entry.alias, host: entry.hostname, port: entry.port)
            machine.authMethod = .passwordOrKey
            machine.username = entry.user
            machine.remark = "Imported from ~/.ssh/config"
            if let path = entry.identityFile {
                if let key = try key(at: path, keys: &keys, context: context, readFile: readFile, notes: &outcome.notes) {
                    machine.sshKey = key
                }
            } else {
                outcome.notes.append("\(entry.alias) has no key file; add a password or key to it.")
            }
            context.insert(machine)
            byAlias[entry.alias] = machine
            outcome.added.append(entry.alias)
        }

        // Jump hosts once every machine exists, so an alias can point at one imported in the same batch.
        let all = existing + Array(byAlias.values)
        for entry in entries where !entry.proxyJump.isEmpty {
            guard let machine = byAlias[entry.alias] else { continue }
            var hops: [UUID] = []
            for hop in entry.proxyJump {
                let host = hop.split(separator: "@").last.map { String($0.split(separator: ":").first ?? "") } ?? hop
                if let match = byAlias[hop] ?? all.first(where: { $0.name == hop || $0.host == host }), match.id != machine.id {
                    hops.append(match.id)
                } else {
                    outcome.notes.append("\(entry.alias): jump host \(hop) isn't in SwiftPulse; add it and set it as the jump host.")
                }
            }
            machine.useJumpHost = !hops.isEmpty
            machine.jumpHostIDs = hops
        }
        try context.save()
        return outcome
    }

    /// The SSH key for a private key file: the one already imported (same public key) or a new one.
    @MainActor
    private static func key(at path: String, keys: inout [SSHKey], context: ModelContext, readFile: (String) -> String?,
                            notes: inout [String]) throws -> SSHKey? {
        let publicKey = readFile(path + ".pub")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (path as NSString).lastPathComponent
        if !publicKey.isEmpty, let known = keys.first(where: { $0.publicKey.split(separator: " ").prefix(2) == publicKey.split(separator: " ").prefix(2) }) {
            return known
        }
        if publicKey.isEmpty, let known = keys.first(where: { $0.name == name && $0.remark == "Imported from \(path)" }) { return known }
        guard let pem = readFile(path), (try? OpenSSHPrivateKey.validate(pem)) != nil else {
            notes.append("\(name) isn't a private key SwiftPulse can read; skipped.")
            return nil
        }
        let type = SSHKeyGenerator.type(fromPublicKey: publicKey)
            ?? (try? OpenSSHPrivateKey.keyType(PKCS1Converter.isPKCS1(pem) ? (try? PKCS1Converter.toOpenSSH(pem)) ?? pem : pem))
                .flatMap { SSHKeyGenerator.type(fromPublicKey: $0) } ?? .ed25519
        let key = SSHKey(name: name, keyType: type, publicKey: publicKey)
        key.remark = "Imported from \(path)"
        if (try? OpenSSHPrivateKey.privateKey(pem, passphrase: nil)) == nil {
            key.hasPassphrase = true
            notes.append("\(name) is protected by a passphrase; enter it in SSH Keys before connecting.")
        }
        KeychainService.set(pem, for: key.privateKeyKey)
        context.insert(key)
        keys.append(key)
        return key
    }
}
