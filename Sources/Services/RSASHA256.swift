import Foundation
import BigInt
import NIOCore
import NIOSSH
import Security

/// "rsa-sha2-256" public key algorithm for NIOSSH (RFC 8332), signing/verifying through Security.framework.
/// Citadel only ships SHA-1 "ssh-rsa", which modern OpenSSH servers reject. Used for userauth only (not registered as a host key algorithm).
enum RSASHA256 {
    static let name = "rsa-sha2-256"
    enum RSAError: LocalizedError {
        case malformed, security(String)
        var errorDescription: String? {
            switch self {
            case .malformed: "RSA key is malformed."
            case .security(let s): "RSA operation failed: \(s)"
            }
        }
    }

    final class PublicKey: NIOSSHPublicKeyProtocol {
        static let publicKeyPrefix = RSASHA256.name
        let n: Data, e: Data
        init(n: Data, e: Data) { self.n = n; self.e = e }

        var rawRepresentation: Data { mpint(e) + mpint(n) }
        func write(to buffer: inout ByteBuffer) -> Int { buffer.writeBytes(rawRepresentation) }
        static func read(from buffer: inout ByteBuffer) throws -> PublicKey {
            guard let e = buffer.readSSHBytes(), let n = buffer.readSSHBytes() else { throw RSAError.malformed }
            return PublicKey(n: n, e: e)
        }
        func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
            guard let sig = signature as? Signature,
                  let key = try? RSASHA256.secKey(der: DER.sequence([DER.integer(n), DER.integer(e)]), isPrivate: false) else { return false }
            return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(data) as CFData, sig.rawRepresentation as CFData, nil)
        }
    }

    final class PrivateKey: NIOSSHPrivateKeyProtocol {
        static let keyPrefix = RSASHA256.name
        let pub: PublicKey
        private let key: SecKey

        /// Components as found in an OpenSSH private key section: n, e, d, iqmp, p, q.
        init(n: Data, e: Data, d: Data, iqmp: Data, p: Data, q: Data) throws {
            pub = PublicKey(n: n, e: e)
            let bd = BigUInt(d), bp = BigUInt(p), bq = BigUInt(q)
            let dp = bd % (bp - 1), dq = bd % (bq - 1)
            let der = DER.sequence([
                DER.integer(Data([0])), DER.integer(n), DER.integer(e), DER.integer(d),
                DER.integer(p), DER.integer(q), DER.integer(dp.serialize()), DER.integer(dq.serialize()), DER.integer(iqmp),
            ])
            key = try RSASHA256.secKey(der: der, isPrivate: true)
        }

        var publicKey: NIOSSHPublicKeyProtocol { pub }
        func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            var error: Unmanaged<CFError>?
            guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(data) as CFData, &error) else {
                throw RSAError.security(error?.takeRetainedValue().localizedDescription ?? "signature failed")
            }
            return Signature(rawRepresentation: sig as Data)
        }
    }

    struct Signature: NIOSSHSignatureProtocol {
        static let signaturePrefix = RSASHA256.name
        let rawRepresentation: Data
        func write(to buffer: inout ByteBuffer) -> Int { buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation) }
        static func read(from buffer: inout ByteBuffer) throws -> Signature {
            guard let bytes = buffer.readSSHBytes() else { throw RSAError.malformed }
            return Signature(rawRepresentation: bytes)
        }
    }

    static func secKey(der: Data, isPrivate: Bool) throws -> SecKey {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                      kSecAttrKeyClass: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw RSAError.security(error?.takeRetainedValue().localizedDescription ?? "invalid key data")
        }
        return key
    }

    static func mpint(_ raw: Data) -> Data {
        var bytes = Data(raw.drop { $0 == 0 })
        if let f = bytes.first, f & 0x80 != 0 { bytes.insert(0, at: 0) }
        if bytes.isEmpty { bytes = Data([0]) }
        return withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Data($0) } + bytes
    }

    /// Minimal DER writer for PKCS#1 structures.
    enum DER {
        static func integer(_ raw: Data) -> Data {
            var bytes = Data(raw.drop { $0 == 0 })
            if bytes.isEmpty { bytes = Data([0]) }
            if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02]) + length(bytes.count) + bytes
        }
        static func sequence(_ items: [Data]) -> Data {
            let body = items.reduce(Data(), +)
            return Data([0x30]) + length(body.count) + body
        }
        static func length(_ n: Int) -> Data {
            if n < 0x80 { return Data([UInt8(n)]) }
            var v = n, out = Data()
            while v > 0 { out.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
            return Data([0x80 | UInt8(out.count)]) + out
        }
    }
}

private extension ByteBuffer {
    mutating func readSSHBytes() -> Data? {
        guard let len = readInteger(as: UInt32.self), let bytes = readBytes(length: Int(len)) else { return nil }
        return Data(bytes)
    }
}
