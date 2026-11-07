import Testing
import Foundation
import SwiftData
@testable import SwiftPulse

@MainActor @Suite(.serialized)
struct SSHConfigImportTests {
    @Test func aliasesSkipPatternsAndFollowIncludes() throws {
        let parsed = SSHConfigImport.parse("""
        # comment
        Include conf.d/*
        Host web db  "quoted"
            HostName 10.0.0.1
        Host *.internal !bastion
        host=lower
        Match host foo
        """)
        #expect(parsed.aliases == ["web", "db", "quoted", "lower"])
        #expect(parsed.includes == ["conf.d/*"])

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sshcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Include \(folder.path)/conf.d/*\nHost main web".write(to: folder.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host extra\nHost web".write(to: folder.appendingPathComponent("conf.d/a.conf"), atomically: true, encoding: .utf8)
        let all = SSHConfigImport.aliases(config: folder.appendingPathComponent("config"))
        #expect(Set(all) == ["main", "web", "extra"] && all.count == 3) // included files read, "web" listed once
    }

    @Test func sshGOutputBecomesAnEntry() {
        let entry = SSHConfigImport.entry(alias: "db", sshG: """
        user ubuntu
        hostname 10.0.0.2
        port 2198
        identityfile ~/.ssh/missing
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/id_rsa
        proxyjump bastion,ops@10.0.0.9:2222
        """, fileExists: { !$0.hasSuffix("missing") })
        #expect(entry.hostname == "10.0.0.2" && entry.port == 2198 && entry.user == "ubuntu")
        #expect(entry.identityFile == ("~/.ssh/id_ed25519" as NSString).expandingTildeInPath)
        #expect(entry.proxyJump == ["bastion", "ops@10.0.0.9:2222"])
        #expect(SSHConfigImport.entry(alias: "x", sshG: "proxyjump none").proxyJump.isEmpty)
    }

    @Test func importAddsMachinesKeysAndJumpHosts() throws {
        let secrets = FileManager.default.temporaryDirectory.appendingPathComponent("sshcfg-secrets-\(UUID().uuidString).json")
        KeychainService.overrideStoreURL = secrets
        defer { KeychainService.overrideStoreURL = nil; try? FileManager.default.removeItem(at: secrets) }
        let container = AppSchema.container(inMemory: true) // kept: a main context doesn't keep its container alive
        let context = container.mainContext
        let existing = Machine(name: "old", host: "10.0.0.5", port: 22)
        existing.username = "root"
        context.insert(existing)

        let pair = try SSHKeyGenerator.generate(.ed25519, comment: "test")
        let files = ["/k/id_ed25519": pair.privateKey, "/k/id_ed25519.pub": pair.publicKey]
        let entries = [
            SSHConfigImport.Entry(alias: "bastion", hostname: "1.2.3.4", port: 22, user: "ops", identityFile: "/k/id_ed25519", proxyJump: []),
            SSHConfigImport.Entry(alias: "app", hostname: "10.0.0.7", port: 22, user: "ubuntu", identityFile: "/k/id_ed25519",
                                  proxyJump: ["bastion", "nowhere"]),
            SSHConfigImport.Entry(alias: "dup", hostname: "10.0.0.5", port: 22, user: "root", identityFile: nil, proxyJump: []),
        ]
        let outcome = try SSHConfigImport.importEntries(entries, into: context, readFile: { files[$0] })
        #expect(outcome.added == ["bastion", "app"] && outcome.skipped == ["dup"])
        #expect(outcome.notes.contains { $0.contains("nowhere") })

        let machines = try context.fetch(FetchDescriptor<Machine>())
        let app = try #require(machines.first { $0.name == "app" })
        let bastion = try #require(machines.first { $0.name == "bastion" })
        #expect(app.useJumpHost && app.jumpHostIDs == [bastion.id])
        #expect(app.username == "ubuntu" && app.authMethod == .passwordOrKey)
        let keys = try context.fetch(FetchDescriptor<SSHKey>())
        #expect(keys.count == 1) // both machines share the one key file
        #expect(app.sshKey?.id == keys[0].id && bastion.sshKey?.id == keys[0].id)
        #expect(KeychainService.get(keys[0].privateKeyKey) == pair.privateKey)
    }
}
