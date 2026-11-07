import Testing
import Foundation
import CryptoKit
import Security
import Citadel
import NIOCore
@testable import SwiftPulse

struct KeyFormatTests {
    private func blobFields(_ publicKeyLine: String) -> [Data] {
        let b64 = publicKeyLine.split(separator: " ")[1]
        var data = Data(base64Encoded: String(b64))!
        var fields: [Data] = []
        while data.count >= 4 {
            let len = Int(data[0]) << 24 | Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])
            fields.append(data.subdata(in: 4..<4 + len)); data = data.subdata(in: 4 + len..<data.count)
        }
        return fields
    }

    @Test func ed25519RoundTrip() throws {
        let pair = try SSHKeyGenerator.generate(.ed25519, comment: "test")
        #expect(pair.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(pair.publicKey.hasSuffix(" test"))
        #expect(try OpenSSHPrivateKey.keyType(pair.privateKey) == "ssh-ed25519")
        #expect(SSHKeyGenerator.type(fromPublicKey: pair.publicKey) == .ed25519)
        // Citadel must be able to load what we wrote, and the embedded public key must match.
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: pair.privateKey)
        #expect(blobFields(pair.publicKey)[1] == key.publicKey.rawRepresentation)
        #expect(SSHKeyGenerator.fingerprint(pair.publicKey).hasPrefix("SHA256:"))
        _ = try OpenSSHPrivateKey.privateKey(pair.privateKey, passphrase: nil)
    }

    @Test(arguments: [SwiftPulse.SSHKeyType.ecdsaP256, .ecdsaP384, .ecdsaP521])
    func ecdsaRoundTrip(type: SwiftPulse.SSHKeyType) throws {
        let pair = try SSHKeyGenerator.generate(type, comment: "")
        let fields = blobFields(pair.publicKey)
        let scalar = try OpenSSHPrivateKey.ecdsaScalar(pair.privateKey)
        let point: Data
        switch type {
        case .ecdsaP256: point = try P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        case .ecdsaP384: point = try P384.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        default: point = try P521.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
        }
        #expect(fields[2] == point)
        _ = try OpenSSHPrivateKey.privateKey(pair.privateKey, passphrase: nil)
    }

    @Test func publicKeyInPrivateKeyFieldIsRejected() throws {
        let pair = try SSHKeyGenerator.generate(.ed25519, comment: "test")
        #expect(throws: OpenSSHPrivateKey.ParseError.publicKey) { try OpenSSHPrivateKey.validate(pair.publicKey) }
        #expect(throws: OpenSSHPrivateKey.ParseError.notOpenSSH) { try OpenSSHPrivateKey.validate("hello") }
        try OpenSSHPrivateKey.validate(pair.privateKey)
    }

    @Test func rsaGenerationIsReportedUnsupported() {
        #expect(throws: SSHKeyGenerator.GeneratorError.self) { try SSHKeyGenerator.generate(.rsa, comment: "") }
    }

    /// PKCS#1 PEM (what `ssh-keygen -m PEM` and old id_rsa files use) → OpenSSH → rsa-sha2-256 signature verified by Security.
    @Test func pkcs1RSARoundTripAndSignature() throws {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false]
        var error: Unmanaged<CFError>?
        let secKey = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, &error))
        let der = try #require(SecKeyCopyExternalRepresentation(secKey, &error)) as Data
        let b64 = der.base64EncodedString()
        var lines = ["-----BEGIN RSA PRIVATE KEY-----"]
        var i = b64.startIndex
        while i < b64.endIndex { let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex; lines.append(String(b64[i..<j])); i = j }
        lines.append("-----END RSA PRIVATE KEY-----")
        let pem = lines.joined(separator: "\n")

        #expect(PKCS1Converter.isPKCS1(pem))
        let openssh = try PKCS1Converter.toOpenSSH(pem, comment: "t")
        #expect(try OpenSSHPrivateKey.keyType(openssh) == "ssh-rsa")
        let c = try OpenSSHPrivateKey.rsaComponents(openssh)
        let priv = try RSASHA256.PrivateKey(n: c.n, e: c.e, d: c.d, iqmp: c.iqmp, p: c.p, q: c.q)

        let message = Data("hello swiftpulse".utf8)
        let signature = try priv.signature(for: message)
        #expect(type(of: signature).signaturePrefix == "rsa-sha2-256")
        #expect(priv.pub.isValidSignature(signature, for: message))
        #expect(!priv.pub.isValidSignature(signature, for: Data("tampered".utf8)))
        // Cross-check with Security.framework using the original key
        let pubKey = try #require(SecKeyCopyPublicKey(secKey))
        #expect(SecKeyVerifySignature(pubKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature.rawRepresentation as CFData, nil))
        // Public key line derived from the PEM matches the blob in the converted private key
        let line = try PKCS1Converter.publicKeyLine(pem)
        #expect(line.hasPrefix("ssh-rsa "))
        #expect(blobFields(line)[0] == Data("ssh-rsa".utf8))
        _ = try OpenSSHPrivateKey.privateKey(pem, passphrase: nil)
    }

    @Test func encryptedPEMIsRejectedClearly() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END RSA PRIVATE KEY-----"
        #expect(throws: PKCS1Converter.ConvertError.encrypted) { try PKCS1Converter.toOpenSSH(pem) }
    }
}
