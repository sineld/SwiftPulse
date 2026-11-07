import Foundation
import CryptoKit
import CommonCrypto

/// Passphrase-based encryption for the sync vault: PBKDF2-HMAC-SHA256 for the key, AES-GCM for the payload.
/// The vault lands in a cloud-synced folder, so the secrets inside it (SSH private keys, passwords) are
/// never written in the clear.
enum VaultCrypto {
    /// For new vaults. A vault keeps the count it was written with, so older files (210 000) still open.
    static let iterations = 600_000
    /// What a vault file may ask for: a huge count in a damaged or hostile file would hang the import.
    static let iterationRange = 100_000...10_000_000
    static let saltLength = 16

    enum CryptoError: LocalizedError, Equatable {
        case emptyPassphrase, derivationFailed, wrongPassphrase, untrustedIterations(Int)
        var errorDescription: String? {
            switch self {
            case .emptyPassphrase: "Set a sync passphrase first."
            case .derivationFailed: "Could not derive the encryption key."
            case .wrongPassphrase: "Wrong passphrase, or the vault file is damaged."
            case .untrustedIterations(let count): "The vault file asks for \(count) key derivation rounds, which SwiftPulse never writes. The file is damaged or not from SwiftPulse."
            }
        }
    }

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// The same passphrase typed on two Macs can arrive as different Unicode sequences (é as one character or as
    /// e plus an accent); keys are derived from its canonical composed form so both give the same key.
    static func normalized(_ passphrase: String) -> String { passphrase.precomposedStringWithCanonicalMapping }

    static func derive(passphrase: String, salt: Data, iterations: Int = iterations) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw CryptoError.emptyPassphrase }
        guard iterationRange.contains(iterations) else { throw CryptoError.untrustedIterations(iterations) }
        return try pbkdf2(normalized(passphrase), salt: salt, iterations: iterations)
    }

    /// The raw derivation, without the checks or normalization `derive` adds (internal for tests).
    static func pbkdf2(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let status: Int32 = passphrase.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBufferPointer { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         password, passphrase.utf8.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         output.baseAddress, output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.derivationFailed }
        return SymmetricKey(data: Data(derived))
    }

    /// Returns the salt used and the sealed box (nonce + ciphertext + tag).
    static func seal(_ plaintext: Data, passphrase: String) throws -> (salt: Data, payload: Data) {
        let salt = randomSalt()
        let key = try derive(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.derivationFailed }
        return (salt, combined)
    }

    static func open(payload: Data, salt: Data, passphrase: String, iterations: Int = iterations) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: payload) else { throw CryptoError.wrongPassphrase }
        let key = try derive(passphrase: passphrase, salt: salt, iterations: iterations)
        if let plaintext = try? AES.GCM.open(box, using: key) { return plaintext }
        // Vaults written before keys came from the normalized passphrase used it exactly as typed. Bytes, not
        // String ==, which treats the two forms as equal.
        if !normalized(passphrase).utf8.elementsEqual(passphrase.utf8), let plaintext = try? AES.GCM.open(box, using: pbkdf2(passphrase, salt: salt, iterations: iterations)) {
            return plaintext
        }
        throw CryptoError.wrongPassphrase
    }
}
