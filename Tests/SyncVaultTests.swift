import Testing
import Foundation
import SwiftData
@testable import SwiftPulse

/// Redirects the secret store and preferences at temporary storage, so the suite never touches real data.
@MainActor
private final class Scratch {
    let secretsURL: URL
    let suiteName: String
    let defaults: UserDefaults

    init() {
        secretsURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftpulse-secrets-\(UUID().uuidString).json")
        (suiteName, defaults) = TestDefaults.make()
        KeychainService.overrideStoreURL = secretsURL
        SyncVault.defaults = defaults
    }

    deinit {
        try? FileManager.default.removeItem(at: secretsURL)
        TestDefaults.discard(suiteName)
        KeychainService.overrideStoreURL = nil
        SyncVault.defaults = .standard
    }

    func context() -> ModelContext { ModelContext(AppSchema.container(inMemory: true)) }

    /// One machine that exercises every relationship, plus a snippet, a rule and a trusted host key.
    @discardableResult
    func seed(_ context: ModelContext) throws -> (Machine, Identity, SSHKey, Proxy, MachineGroup) {
        let key = SSHKey(name: "work-laptop", keyType: .ed25519, publicKey: "ssh-ed25519 AAAA")
        key.hasPassphrase = true
        context.insert(key)
        KeychainService.set("PRIVATE-KEY-BODY", for: key.privateKeyKey)
        KeychainService.set("key-passphrase", for: key.passphraseKey)

        let identity = Identity(name: "deploy", username: "ubuntu")
        identity.sshKey = key
        identity.hasPassword = true
        context.insert(identity)
        KeychainService.set("identity-secret", for: identity.passwordKey)

        let proxy = Proxy(name: "office", host: "10.0.0.1", port: 1080)
        proxy.auth = .usernamePassword
        proxy.username = "alice"
        context.insert(proxy)
        KeychainService.set("proxy-secret", for: proxy.passwordKey)

        let group = MachineGroup(name: "Production")
        context.insert(group)

        let bastion = Machine(name: "bastion", host: "bastion.example", port: 22)
        bastion.identity = identity
        context.insert(bastion)

        let machine = Machine(name: "Production", host: "203.0.113.10", port: 2198)
        machine.authMethod = .identity
        machine.identity = identity
        machine.proxy = proxy
        machine.group = group
        machine.tags = ["prod", "vpn"]
        machine.useJumpHost = true
        machine.jumpHostIDs = [bastion.id]
        machine.defaultSFTPPath = "/srv"
        machine.connection = .ssh
        context.insert(machine)
        KeychainService.set("machine-secret", for: machine.passwordKey)

        let package = SnippetPackage(name: "Maintenance")
        context.insert(package)
        let snippet = Snippet(name: "Disk usage")
        snippet.script = "df -h /"
        snippet.package = package
        context.insert(snippet)

        let rule = PortForwardingRule(name: "sshd")
        rule.mode = .local
        rule.machineID = machine.id
        rule.localPort = 18081
        rule.targetPort = 2198
        rule.autoStart = true
        context.insert(rule)

        context.insert(KnownHostKey(host: "203.0.113.10", port: 2198, keyType: "ssh-ed25519", publicKeyBase64: "AAAAC3Nza"))

        defaults.set(42, forKey: "connectionTimeout")
        defaults.set(true, forKey: "alwaysTrustHostKeys")
        defaults.set("Menlo", forKey: "terminalFontName")
        defaults.set(13.5, forKey: "terminalFontSize")

        try context.save()
        return (machine, identity, key, proxy, group)
    }
}

@MainActor
struct SyncVaultTests {

    @Test func vaultCarriesEveryResourceAndSecret() throws {
        let scratch = Scratch()
        let context = scratch.context()
        try scratch.seed(context)

        let vault = try SyncVault.build(from: context)
        #expect(vault.machines.count == 2)
        #expect(vault.identities.count == 1)
        #expect(vault.sshKeys.count == 1)
        #expect(vault.proxies.count == 1)
        #expect(vault.groups.count == 1)
        #expect(vault.snippets.count == 1)
        #expect(vault.packages.count == 1)
        #expect(vault.forwardingRules.count == 1)
        #expect(vault.knownHosts.count == 1)
        // secrets: machine password, identity password, proxy password, private key, key passphrase
        #expect(vault.secrets.count == 5)
        #expect(vault.secrets.values.contains("PRIVATE-KEY-BODY"))
        #expect(vault.settings["connectionTimeout"] == .int(42))
        #expect(vault.settings["alwaysTrustHostKeys"] == .bool(true))
        #expect(vault.settings["terminalFontName"] == .string("Menlo"))
        #expect(vault.settings["terminalFontSize"] == .double(13.5))
        // session history stays on the device that made it
        #expect(!vault.counts.contains { $0.0 == "Sessions" })
    }

    @Test func fileIsEncryptedButItsHeaderStaysReadable() throws {
        let scratch = Scratch()
        let context = scratch.context()
        try scratch.seed(context)
        let vault = try SyncVault.build(from: context)

        let data = try vault.fileData(passphrase: "correct horse")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("PRIVATE-KEY-BODY"))
        #expect(!text.contains("203.0.113.10"))

        let envelope = try SyncVault.envelope(from: data)   // no passphrase needed
        #expect(envelope.format == "swiftpulse.vault")
        #expect(envelope.device == SyncVault.deviceName)
        #expect(envelope.iterations == VaultCrypto.iterations)

        #expect(throws: VaultCrypto.CryptoError.wrongPassphrase) {
            _ = try SyncVault.read(data, passphrase: "wrong horse")
        }
        let (restored, _) = try SyncVault.read(data, passphrase: "correct horse")
        #expect(restored.machines.count == 2)
        #expect(restored.secrets == vault.secrets)
    }

    @Test func importRebuildsRelationshipsSecretsAndSettingsOnAFreshDevice() throws {
        let scratch = Scratch()
        let source = scratch.context()
        try scratch.seed(source)
        let vault = try SyncVault.build(from: source)
        let file = try vault.fileData(passphrase: "pass")

        // a second "device": empty store, empty secrets, empty preferences
        let fresh = scratch.context()
        for key in vault.secrets.keys { KeychainService.delete(key) }
        for key in SyncVault.settingKeys.keys { scratch.defaults.removeObject(forKey: key) }

        let (decoded, _) = try SyncVault.read(file, passphrase: "pass")
        let summary = try SyncVault.apply(decoded, to: fresh, strategy: .replace)
        #expect(summary.inserted == 10)     // 2 machines, identity, key, proxy, group, package, snippet, rule, host key
        #expect(summary.secrets == 5)

        let machines = try fresh.fetch(FetchDescriptor<Machine>())
        let machine = try #require(machines.first { $0.name == "Production" })
        #expect(machine.host == "203.0.113.10")
        #expect(machine.port == 2198)
        #expect(machine.identity?.name == "deploy")
        #expect(machine.identity?.sshKey?.name == "work-laptop")
        #expect(machine.proxy?.name == "office")
        #expect(machine.group?.name == "Production")
        #expect(machine.tags == ["prod", "vpn"])
        #expect(machine.useJumpHost)
        #expect(machine.jumpHostIDs.count == 1)
        #expect(machines.contains { $0.id == machine.jumpHostIDs[0] })   // the jump host came along

        let identity = try #require(try fresh.fetch(FetchDescriptor<Identity>()).first)
        #expect(KeychainService.get(identity.passwordKey) == "identity-secret")
        let key = try #require(try fresh.fetch(FetchDescriptor<SSHKey>()).first)
        #expect(KeychainService.get(key.privateKeyKey) == "PRIVATE-KEY-BODY")
        #expect(KeychainService.get(key.passphraseKey) == "key-passphrase")

        let snippet = try #require(try fresh.fetch(FetchDescriptor<Snippet>()).first)
        #expect(snippet.package?.name == "Maintenance")
        let rule = try #require(try fresh.fetch(FetchDescriptor<PortForwardingRule>()).first)
        #expect(rule.machineID == machine.id)
        #expect(rule.localPort == 18081)
        #expect(try fresh.fetch(FetchDescriptor<KnownHostKey>()).count == 1)

        #expect(scratch.defaults.integer(forKey: "connectionTimeout") == 42)
        #expect(scratch.defaults.string(forKey: "terminalFontName") == "Menlo")
    }

    @Test func mergeKeepsLocalExtrasAndUpdatesChangedRows() throws {
        let scratch = Scratch()
        let source = scratch.context()
        try scratch.seed(source)
        let vault = try SyncVault.build(from: source)

        // the "other Mac": import once so the ids line up, then add something only it has
        let target = scratch.context()
        _ = try SyncVault.apply(vault, to: target, strategy: .merge)
        let local = Machine(name: "only-here", host: "192.168.1.5", port: 22)
        target.insert(local)
        try target.save()

        // the vault changes elsewhere and is imported again
        var edited = vault
        edited.machines = vault.machines.map { machine in
            var copy = machine
            if copy.name == "Production" { copy.port = 2222; copy.remark = "edited elsewhere" }
            return copy
        }
        let summary = try SyncVault.apply(edited, to: target, strategy: .merge)
        #expect(summary.deleted == 0)
        #expect(summary.inserted == 0)
        #expect(summary.updated == 9)

        let machines = try target.fetch(FetchDescriptor<Machine>())
        #expect(machines.count == 3)                   // 2 from the vault + the local one
        #expect(machines.contains { $0.name == "only-here" })
        let production = try #require(machines.first { $0.name == "Production" })
        #expect(production.port == 2222)
        #expect(production.remark == "edited elsewhere")
        #expect(production.identity?.name == "deploy")        // relationships survive a re-import
    }

    @Test func replaceDropsLocalRowsThatAreNotInTheVault() throws {
        let scratch = Scratch()
        let source = scratch.context()
        try scratch.seed(source)
        let vault = try SyncVault.build(from: source)

        let target = scratch.context()
        let stale = Machine(name: "retired", host: "10.9.9.9", port: 22)
        target.insert(stale)
        KeychainService.set("stale-secret", for: stale.passwordKey)
        try target.save()

        _ = try SyncVault.apply(vault, to: target, strategy: .replace)
        let machines = try target.fetch(FetchDescriptor<Machine>())
        #expect(machines.count == 2)
        #expect(!machines.contains { $0.name == "retired" })
        #expect(KeychainService.get(stale.passwordKey) == nil)   // its secret went too
    }

    @Test func cryptoRejectsAnEmptyPassphraseAndSurvivesARoundTrip() throws {
        let salt = VaultCrypto.randomSalt()
        #expect(salt.count == VaultCrypto.saltLength)
        #expect(throws: VaultCrypto.CryptoError.emptyPassphrase) {
            _ = try VaultCrypto.derive(passphrase: "", salt: salt)
        }
        let payload = Data("swiftpulse".utf8)
        let sealed = try VaultCrypto.seal(payload, passphrase: "s3cret")
        #expect(sealed.payload != payload)
        let opened = try VaultCrypto.open(payload: sealed.payload, salt: sealed.salt, passphrase: "s3cret")
        #expect(opened == payload)
        #expect(throws: VaultCrypto.CryptoError.wrongPassphrase) {
            _ = try VaultCrypto.open(payload: sealed.payload, salt: sealed.salt, passphrase: "s3cret!")
        }
        // same passphrase, different salt → different key, so the payload must not open
        #expect(throws: VaultCrypto.CryptoError.wrongPassphrase) {
            _ = try VaultCrypto.open(payload: sealed.payload, salt: VaultCrypto.randomSalt(), passphrase: "s3cret")
        }
    }

    @Test func nonVaultFilesAreRejectedByFormat() {
        let json = Data(#"{"format":"something-else","version":1,"exportedAt":"2026-09-08T00:00:00Z","device":"x","app":"1","kdf":"pbkdf2-sha256","iterations":1,"salt":"","payload":""}"#.utf8)
        #expect(throws: SyncVault.VaultError.unsupportedFormat("something-else")) {
            _ = try SyncVault.envelope(from: json)
        }
        #expect(throws: (any Error).self) { _ = try SyncVault.envelope(from: Data("not json".utf8)) }
    }
}
