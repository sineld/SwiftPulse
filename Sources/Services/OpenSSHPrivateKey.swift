import Foundation
import CryptoKit
import Citadel
import NIOSSH
import Crypto

/// Minimal OpenSSH private key decoder for the curves Citadel does not parse itself (ECDSA),
/// plus a helper that turns any stored private key into a Citadel authentication method.
enum OpenSSHPrivateKey {
    enum ParseError: LocalizedError, Equatable {
        case notOpenSSH, publicKey, malformed, unsupported(String), encrypted
        var errorDescription: String? {
            switch self {
            case .notOpenSSH: "Not an OpenSSH private key."
            case .publicKey: "This is a public key. Use the private key file instead (the one without .pub)."
            case .malformed: "The private key is malformed."
            case .unsupported(let t): "Unsupported key type \(t)."
            case .encrypted: "Encrypted private keys need a passphrase (not supported yet for this key type)."
            }
        }
    }

    /// Builds the NIOSSH private key for an OpenSSH/PEM private key string.
    static func privateKey(_ privateKey: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        let privateKey = PKCS1Converter.isPKCS1(privateKey) ? try PKCS1Converter.toOpenSSH(privateKey) : privateKey
        let type = try keyType(privateKey)
        switch type {
        case "ssh-rsa":
            let c = try rsaComponents(privateKey)
            return NIOSSHPrivateKey(custom: try RSASHA256.PrivateKey(n: c.n, e: c.e, d: c.d, iqmp: c.iqmp, p: c.p, q: c.q))
        case "ssh-ed25519":
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(sshEd25519: privateKey, decryptionKey: decryptionKey))
        case "ecdsa-sha2-nistp256":
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: try ecdsaScalar(privateKey)))
        case "ecdsa-sha2-nistp384":
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: try ecdsaScalar(privateKey)))
        case "ecdsa-sha2-nistp521":
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: try ecdsaScalar(privateKey)))
        default:
            throw ParseError.unsupported(type)
        }
    }

    /// Throws why the text cannot be used as a private key, without decrypting it.
    static func validate(_ privateKey: String) throws {
        _ = try keyType(PKCS1Converter.isPKCS1(privateKey) ? try PKCS1Converter.toOpenSSH(privateKey) : privateKey)
    }

    /// Components of an unencrypted OpenSSH RSA private key.
    static func rsaComponents(_ pem: String) throws -> (n: Data, e: Data, d: Data, iqmp: Data, p: Data, q: Data) {
        var reader = try Reader(pem)
        guard try reader.string() == "none" else { throw ParseError.encrypted }
        _ = try reader.string(); _ = try reader.bytes(); _ = try reader.uint32(); _ = try reader.bytes()
        var priv = Reader(data: try reader.bytes())
        _ = try priv.uint32(); _ = try priv.uint32()
        guard String(decoding: try priv.bytes(), as: UTF8.self) == "ssh-rsa" else { throw ParseError.malformed }
        let n = try priv.bytes(), e = try priv.bytes(), d = try priv.bytes(), iqmp = try priv.bytes(), p = try priv.bytes(), q = try priv.bytes()
        return (n, e, d, iqmp, p, q)
    }

    /// Key algorithm name from the public key blob embedded in an OpenSSH private key.
    static func keyType(_ pem: String) throws -> String {
        var reader = try Reader(pem)
        _ = try reader.string() // cipher
        _ = try reader.string() // kdf
        _ = try reader.bytes()  // kdf options
        _ = try reader.uint32() // key count
        var pub = Reader(data: try reader.bytes())
        return String(decoding: try pub.bytes(), as: UTF8.self)
    }

    /// Raw scalar of an unencrypted ECDSA OpenSSH private key (left-padded to the curve size by CryptoKit's init).
    static func ecdsaScalar(_ pem: String) throws -> Data {
        var reader = try Reader(pem)
        let cipher = try reader.string()
        guard cipher == "none" else { throw ParseError.encrypted }
        _ = try reader.string(); _ = try reader.bytes(); _ = try reader.uint32(); _ = try reader.bytes()
        var priv = Reader(data: try reader.bytes())
        _ = try priv.uint32(); _ = try priv.uint32()      // check ints
        let type = String(decoding: try priv.bytes(), as: UTF8.self)
        _ = try priv.bytes() // curve name
        _ = try priv.bytes() // public point
        var scalar = try priv.bytes()
        let size = type.hasSuffix("256") ? 32 : type.hasSuffix("384") ? 48 : 66
        while scalar.count > size, scalar.first == 0 { scalar.removeFirst() }
        while scalar.count < size { scalar.insert(0, at: 0) }
        return scalar
    }

    private struct Reader {
        var data: Data
        var offset = 0
        init(data: Data) { self.data = data }
        init(_ pem: String) throws {
            let lines = pem.split(whereSeparator: \.isNewline).map(String.init)
            if lines.first.flatMap(SSHKeyGenerator.type(fromPublicKey:)) != nil { throw ParseError.publicKey }
            guard lines.first?.contains("BEGIN OPENSSH PRIVATE KEY") == true else { throw ParseError.notOpenSSH }
            let body = lines.dropFirst().filter { !$0.contains("END OPENSSH") }.joined()
            guard let raw = Data(base64Encoded: body), raw.starts(with: Data("openssh-key-v1\0".utf8)) else { throw ParseError.malformed }
            data = raw; offset = 15
        }
        mutating func uint32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw ParseError.malformed }
            let v = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            offset += 4; return v
        }
        mutating func bytes() throws -> Data {
            let n = Int(try uint32())
            guard offset + n <= data.count else { throw ParseError.malformed }
            defer { offset += n }
            return Data(data[offset..<offset + n])
        }
        mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
    }
}
