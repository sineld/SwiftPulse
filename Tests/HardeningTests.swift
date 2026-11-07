import Testing
import Foundation
import CryptoKit
@testable import SwiftPulse

// Nested so it never runs alongside the other suites that swap shared test hooks.
extension SharedStateTests {
struct HardeningTests {
    @Test func changedHostKeysAlwaysAsk() {
        typealias D = HostKeyStore.Decision
        #expect(HostKeyStore.decide(offered: "A", known: ["A"], autoTrust: true, alwaysTrust: false) == D.accept)
        #expect(HostKeyStore.decide(offered: "A", known: [], autoTrust: true, alwaysTrust: false) == D.ask(changed: false))
        #expect(HostKeyStore.decide(offered: "A", known: [], autoTrust: true, alwaysTrust: true) == D.trust)
        // The setting never covers a key that differs from the saved one…
        #expect(HostKeyStore.decide(offered: "B", known: ["A"], autoTrust: true, alwaysTrust: true) == D.ask(changed: true))
        // …and agents (autoTrust: false) never get it at all.
        #expect(HostKeyStore.decide(offered: "A", known: [], autoTrust: false, alwaysTrust: true) == D.ask(changed: false))
    }

    @Test func vaultsWrittenWithFewerRoundsStillOpen() throws {
        let salt = VaultCrypto.randomSalt()
        let key = try VaultCrypto.derive(passphrase: "s3cret", salt: salt, iterations: 210_000)
        let sealed = try #require(try AES.GCM.seal(Data("old vault".utf8), using: key).combined)
        #expect(try VaultCrypto.open(payload: sealed, salt: salt, passphrase: "s3cret", iterations: 210_000) == Data("old vault".utf8))
    }

    @Test func absurdRoundCountsAreRefusedBeforeDeriving() {
        let salt = VaultCrypto.randomSalt()
        #expect(throws: VaultCrypto.CryptoError.untrustedIterations(50)) {
            _ = try VaultCrypto.open(payload: Data(repeating: 1, count: 64), salt: salt, passphrase: "p", iterations: 50)
        }
        #expect(throws: VaultCrypto.CryptoError.untrustedIterations(2_000_000_000)) {
            _ = try VaultCrypto.derive(passphrase: "p", salt: salt, iterations: 2_000_000_000)
        }
    }

    @Test func passphrasesMatchWhateverWayTheyWereTyped() throws {
        let composed = "kahve-\u{00E7}ay-caf\u{00E9}", decomposed = "kahve-c\u{0327}ay-cafe\u{0301}"
        #expect(!composed.utf8.elementsEqual(decomposed.utf8)) // the same text, different bytes
        let sealed = try VaultCrypto.seal(Data("x".utf8), passphrase: composed)
        #expect(try VaultCrypto.open(payload: sealed.payload, salt: sealed.salt, passphrase: decomposed) == Data("x".utf8))

        // A vault from before normalization, keyed with the decomposed form exactly as typed.
        let salt = VaultCrypto.randomSalt()
        let raw = try VaultCrypto.pbkdf2(decomposed, salt: salt, iterations: 210_000)
        let old = try #require(try AES.GCM.seal(Data("y".utf8), using: raw).combined)
        #expect(try VaultCrypto.open(payload: old, salt: salt, passphrase: decomposed, iterations: 210_000) == Data("y".utf8))
        #expect(throws: VaultCrypto.CryptoError.wrongPassphrase) {
            _ = try VaultCrypto.open(payload: old, salt: salt, passphrase: "nope", iterations: 210_000)
        }
    }

    @Test func theSecretsFileIsOwnerOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hardening-\(UUID().uuidString).json")
        KeychainService.overrideStoreURL = url
        defer {
            KeychainService.overrideStoreURL = nil
            try? FileManager.default.removeItem(at: url)
        }
        KeychainService.set("v", for: "k")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
}
