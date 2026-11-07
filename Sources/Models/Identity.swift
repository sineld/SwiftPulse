import Foundation
import SwiftData

@Model
final class Identity {
    var id: UUID = UUID()
    var name: String = ""
    var username: String = ""
    var hasPassword: Bool = false
    var sshKey: SSHKey?
    var remark: String = ""
    var createdAt: Date = Date()

    init(name: String = "", username: String = "") {
        self.name = name
        self.username = username
        self.remark = Machine.defaultRemark()
    }

    var passwordKey: String { "identity.password.\(id.uuidString)" }
}

@Model
final class SSHKey {
    var id: UUID = UUID()
    var name: String = ""
    var keyType: SSHKeyType = SSHKeyType.ed25519
    var publicKey: String = ""
    var hasPassphrase: Bool = false
    var remark: String = ""
    var createdAt: Date = Date()

    init(name: String = "", keyType: SSHKeyType = .ed25519, publicKey: String = "") {
        self.name = name
        self.keyType = keyType
        self.publicKey = publicKey
        self.remark = Machine.defaultRemark()
    }

    var privateKeyKey: String { "sshkey.private.\(id.uuidString)" }
    var passphraseKey: String { "sshkey.passphrase.\(id.uuidString)" }
}

@Model
final class Proxy {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 1080
    var kind: ProxyKind = ProxyKind.socks5
    var auth: ProxyAuth = ProxyAuth.none
    var username: String = ""
    var remark: String = ""
    var createdAt: Date = Date()

    init(name: String = "", host: String = "", port: Int = 1080) {
        self.name = name
        self.host = host
        self.port = port
        self.remark = Machine.defaultRemark()
    }

    var passwordKey: String { "proxy.password.\(id.uuidString)" }
}
