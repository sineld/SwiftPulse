import Foundation

/// Converts a PKCS#1 "BEGIN RSA PRIVATE KEY" PEM into the OpenSSH private key format Citadel can load.
/// Encrypted PKCS#1 (Proc-Type: ENCRYPTED) is not supported. ponytail: PKCS#8 ("BEGIN PRIVATE KEY") not handled yet.
enum PKCS1Converter {
    enum ConvertError: LocalizedError {
        case notPKCS1, encrypted, malformed
        var errorDescription: String? {
            switch self {
            case .notPKCS1: "Not a PKCS#1 RSA private key."
            case .encrypted: "Encrypted PEM keys are not supported; convert with `ssh-keygen -p` first."
            case .malformed: "The RSA key could not be parsed."
            }
        }
    }

    static func isPKCS1(_ pem: String) -> Bool { pem.contains("BEGIN RSA PRIVATE KEY") }

    static func toOpenSSH(_ pem: String, comment: String = "") throws -> String {
        guard isPKCS1(pem) else { throw ConvertError.notPKCS1 }
        guard !pem.contains("ENCRYPTED") else { throw ConvertError.encrypted }
        let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw ConvertError.malformed }
        var reader = DER(der)
        let ints = try reader.rsaSequence()  // version, n, e, d, p, q, dp, dq, qinv
        guard ints.count >= 9 else { throw ConvertError.malformed }
        let n = ints[1], e = ints[2], d = ints[3], p = ints[4], q = ints[5], iqmp = ints[8]

        let pubBlob = sshString("ssh-rsa") + mpint(e) + mpint(n)
        let priv = sshString("ssh-rsa") + mpint(n) + mpint(e) + mpint(d) + mpint(iqmp) + mpint(p) + mpint(q)
        let check = UInt32.random(in: 0...UInt32.max)
        var section = uint32(check) + uint32(check) + priv + sshString(comment)
        var pad: UInt8 = 1
        while section.count % 8 != 0 { section.append(pad); pad += 1 }
        var out = Data("openssh-key-v1\0".utf8)
        out += sshString("none") + sshString("none") + sshString(Data()) + uint32(1) + sshString(pubBlob) + sshString(section)
        let b64 = out.base64EncodedString()
        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var i = b64.startIndex
        while i < b64.endIndex { let j = b64.index(i, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex; lines.append(String(b64[i..<j])); i = j }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        return lines.joined(separator: "\n") + "\n"
    }

    /// OpenSSH public key line for the same PEM ("ssh-rsa AAAA... comment").
    static func publicKeyLine(_ pem: String, comment: String = "") throws -> String {
        let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw ConvertError.malformed }
        var reader = DER(der)
        let ints = try reader.rsaSequence()
        let blob = sshString("ssh-rsa") + mpint(ints[2]) + mpint(ints[1])
        return "ssh-rsa \(blob.base64EncodedString())\(comment.isEmpty ? "" : " " + comment)"
    }

    // MARK: - helpers
    private static func uint32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func sshString(_ s: String) -> Data { sshString(Data(s.utf8)) }
    private static func sshString(_ d: Data) -> Data { uint32(UInt32(d.count)) + d }
    private static func mpint(_ raw: Data) -> Data {
        var bytes = Data(raw.drop { $0 == 0 })
        if let f = bytes.first, f & 0x80 != 0 { bytes.insert(0, at: 0) }
        return sshString(bytes)
    }

    /// Tiny DER reader: only SEQUENCE of INTEGERs (what PKCS#1 RSAPrivateKey is).
    private struct DER {
        let data: Data; var pos = 0
        init(_ d: Data) { data = d }
        mutating func rsaSequence() throws -> [Data] {
            guard try tag() == 0x30 else { throw ConvertError.malformed }
            let end = pos + (try length())
            var ints: [Data] = []
            while pos < end, ints.count < 9 {
                guard try tag() == 0x02 else { throw ConvertError.malformed }
                let len = try length()
                guard pos + len <= data.count else { throw ConvertError.malformed }
                ints.append(Data(data[pos..<pos + len])); pos += len
            }
            return ints
        }
        mutating func tag() throws -> UInt8 { guard pos < data.count else { throw ConvertError.malformed }; defer { pos += 1 }; return data[pos] }
        mutating func length() throws -> Int {
            let first = try tag()
            if first & 0x80 == 0 { return Int(first) }
            let n = Int(first & 0x7f)
            guard n <= 4, pos + n <= data.count else { throw ConvertError.malformed }
            var v = 0
            for _ in 0..<n { v = v << 8 | Int(data[pos]); pos += 1 }
            return v
        }
    }
}
