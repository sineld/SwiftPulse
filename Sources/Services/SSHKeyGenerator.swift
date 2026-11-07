import Foundation
import CryptoKit

/// Generates OpenSSH-formatted key pairs with CryptoKit (no dependencies).
/// ponytail: RSA generation not supported yet (needs PKCS#1 DER → OpenSSH mpint re-encoding); import works for RSA.
enum SSHKeyGenerator {
    struct Pair { let publicKey: String; let privateKey: String }

    static func generate(_ type: SSHKeyType, comment: String) throws -> Pair {
        switch type {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            let pub = key.publicKey.rawRepresentation
            let pubBlob = sshString("ssh-ed25519") + sshString(pub)
            let priv = sshString("ssh-ed25519") + sshString(pub) + sshString(key.rawRepresentation + pub)
            return Pair(publicKey: publicLine("ssh-ed25519", pubBlob, comment),
                        privateKey: openSSHPrivate(pubBlob: pubBlob, privBody: priv, comment: comment))
        case .ecdsaP256:
            let key = P256.Signing.PrivateKey()
            return ecdsa("nistp256", key.publicKey.x963Representation, key.rawRepresentation, comment)
        case .ecdsaP384:
            let key = P384.Signing.PrivateKey()
            return ecdsa("nistp384", key.publicKey.x963Representation, key.rawRepresentation, comment)
        case .ecdsaP521:
            let key = P521.Signing.PrivateKey()
            return ecdsa("nistp521", key.publicKey.x963Representation, key.rawRepresentation, comment)
        case .rsa:
            throw GeneratorError.unsupported("RSA generation is not available yet; import an existing RSA key.")
        }
    }

    enum GeneratorError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? { if case .unsupported(let m) = self { m } else { nil } }
    }

    /// Detects key type from an OpenSSH public key line ("ssh-ed25519 AAAA...").
    static func type(fromPublicKey line: String) -> SSHKeyType? {
        switch line.split(separator: " ").first.map(String.init) {
        case "ssh-ed25519": .ed25519
        case "ecdsa-sha2-nistp256": .ecdsaP256
        case "ecdsa-sha2-nistp384": .ecdsaP384
        case "ecdsa-sha2-nistp521": .ecdsaP521
        case "ssh-rsa": .rsa
        default: nil
        }
    }

    // MARK: - encoding helpers

    private static func ecdsa(_ curve: String, _ pub: Data, _ scalar: Data, _ comment: String) -> Pair {
        let alg = "ecdsa-sha2-" + curve
        let pubBlob = sshString(alg) + sshString(curve) + sshString(pub)
        let priv = pubBlob + sshMPInt(scalar)
        return Pair(publicKey: publicLine(alg, pubBlob, comment),
                    privateKey: openSSHPrivate(pubBlob: pubBlob, privBody: priv, comment: comment))
    }

    private static func publicLine(_ alg: String, _ blob: Data, _ comment: String) -> String {
        "\(alg) \(blob.base64EncodedString())\(comment.isEmpty ? "" : " " + comment)"
    }

    private static func openSSHPrivate(pubBlob: Data, privBody: Data, comment: String) -> String {
        let check = UInt32.random(in: 0...UInt32.max)
        var section = uint32(check) + uint32(check) + privBody + sshString(comment)
        var pad: UInt8 = 1
        while section.count % 8 != 0 { section.append(pad); pad += 1 }
        var out = Data("openssh-key-v1\0".utf8)
        out += sshString("none") + sshString("none") + sshString(Data())
        out += uint32(1) + sshString(pubBlob) + sshString(section)
        let b64 = out.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 70).map { i -> String in
            let start = b64.index(b64.startIndex, offsetBy: i)
            let end = b64.index(start, offsetBy: min(70, b64.count - i))
            return String(b64[start..<end])
        }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----"]).joined(separator: "\n") + "\n"
    }

    private static func uint32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func sshString(_ s: String) -> Data { sshString(Data(s.utf8)) }
    private static func sshString(_ d: Data) -> Data { uint32(UInt32(d.count)) + d }
    private static func sshMPInt(_ d: Data) -> Data {
        var bytes = Data(d.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return sshString(bytes)
    }

    /// SHA256 fingerprint in OpenSSH style for a public key line.
    static func fingerprint(_ publicKey: String) -> String {
        guard let b64 = publicKey.split(separator: " ").dropFirst().first, let data = Data(base64Encoded: String(b64)) else { return "-" }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
