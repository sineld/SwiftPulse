import Foundation
import Security

/// Generic string secret store. Keys follow "<kind>.<field>.<uuid>" (see model `*Key` properties).
///
/// Builds signed with a real team identity use the login keychain. Ad-hoc signed builds (no Team ID, the
/// default until `DEVELOPMENT_TEAM` is set) get a new code signature on every build, which makes the keychain
/// prompt on every read, so they use a JSON file inside the sandbox container instead. The choice is made at
/// runtime from the code signature, so Debug and Release builds on the same Mac share one store, and secrets
/// migrate from the file to the keychain the first time a signed build runs.
enum KeychainService {
    private static let service = "app.swiftpulse.secrets"
    static let usesKeychain: Bool = CodeSignature.teamIdentifier != nil

    /// Tests point this at a temporary file so they never read or write the real secret store.
    static var overrideStoreURL: URL? {
        get { FileSecretStore.overrideURL }
        set { FileSecretStore.overrideURL = newValue }
    }
    private static var usesFileStore: Bool { FileSecretStore.overrideURL != nil || !usesKeychain || isRunningTests }

    /// Tests run in parallel and reset `overrideStoreURL` when they finish, so another test can write in between.
    /// Under a test runner the real keychain and the real secrets.json are therefore never used, override or not.
    static let isRunningTests = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        migrateIfNeeded()
        guard !usesFileStore else { return FileSecretStore.set(value, for: key) }
        guard let value else { return delete(key) }
        var query = base(key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        migrateIfNeeded()
        guard !usesFileStore else { return FileSecretStore.get(key) }
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        guard !usesFileStore else { return FileSecretStore.set(nil, for: key) }
        let status = SecItemDelete(base(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private static var migrated = false
    /// One-time copy of file-stored secrets into the keychain once the app is properly signed.
    private static func migrateIfNeeded() {
        guard usesKeychain, !usesFileStore, !migrated else { return }
        migrated = true
        let pending = FileSecretStore.all()
        guard !pending.isEmpty else { return }
        var allCopied = true
        for (key, value) in pending {
            var query = base(key)
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = Data(value.utf8)
            if SecItemAdd(query as CFDictionary, nil) != errSecSuccess { allCopied = false }
        }
        // Keep the file if any copy failed (locked or denied keychain): it is the only copy, retried next launch.
        if allCopied { FileSecretStore.removeAll() }
    }
}

enum CodeSignature {
    /// Team identifier of the running code, nil for ad-hoc or unsigned builds.
    static let teamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()
}

/// JSON file store used by ad-hoc signed builds (container-private, file protection enabled).
enum FileSecretStore {
    /// Set by tests; nil in the app.
    static var overrideURL: URL?
    private static var url: URL { overrideURL ?? (KeychainService.isRunningTests ? testFallback : AppPaths.secrets) }
    /// Where a test lands when no override is set at that moment: a per-run temporary file, never the real store.
    private static let testFallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftpulse-test-secrets-\(ProcessInfo.processInfo.processIdentifier).json")
    private static let lock = NSLock()

    private static var tightened = false

    private static func load() -> [String: String] {
        if !tightened {
            tightened = true
            restrictToOwner()
        }
        return (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    /// The file holds secrets in the clear (ad-hoc builds), so only the owner may read it.
    private static func restrictToOwner() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func get(_ key: String) -> String? { lock.withLock { load()[key] } }
    static func all() -> [String: String] { lock.withLock { load() } }
    static func removeAll() { lock.withLock { try? FileManager.default.removeItem(at: url) } }

    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        lock.withLock {
            var all = load()
            all[key] = value
            guard let data = try? JSONEncoder().encode(all) else { return false }
            guard (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil else { return false }
            restrictToOwner() // an atomic write replaces the file with a new one at the default mode
            return true
        }
    }
}
