import Foundation
import SwiftData

@Model
final class SnippetPackage {
    var id: UUID = UUID()
    var name: String = ""
    var remark: String = ""
    var createdAt: Date = Date()
    @Relationship(deleteRule: .nullify, inverse: \Snippet.package) var snippets: [Snippet]? = []

    init(name: String = "") {
        self.name = name
        self.remark = Machine.defaultRemark()
    }
}

@Model
final class Snippet {
    var id: UUID = UUID()
    var name: String = ""
    var script: String = "#!/bin/bash\n\n"
    var package: SnippetPackage?
    var remark: String = ""
    var createdAt: Date = Date()

    init(name: String = "") {
        self.name = name
        self.remark = Machine.defaultRemark()
    }
}

@Model
final class PortForwardingRule {
    var id: UUID = UUID()
    var name: String = ""
    var mode: ForwardingMode = ForwardingMode.local
    var machineID: UUID?
    var proxyID: UUID?
    var localHost: String = "127.0.0.1"
    var localPort: Int = 0
    var targetHost: String = "127.0.0.1"
    var targetPort: Int = 80
    var autoStart: Bool = false
    var remark: String = ""
    var createdAt: Date = Date()

    init(name: String = "") {
        self.name = name
        self.remark = Machine.defaultRemark()
    }
}

@Model
final class SessionRecord {
    var id: UUID = UUID()
    var kind: SessionKind = SessionKind.terminal
    var machineID: UUID?
    var machineName: String = ""
    var host: String = ""
    var port: Int = 22
    var authMethod: AuthMethod = AuthMethod.identity
    var username: String = ""
    var createdAt: Date = Date()
    var lastActiveAt: Date = Date()

    init(kind: SessionKind, machine: Machine, username: String) {
        self.kind = kind
        self.machineID = machine.id
        self.machineName = machine.displayName
        self.host = machine.host
        self.port = machine.port
        self.authMethod = machine.authMethod
        self.username = username
    }
}

@Model
final class KnownHostKey {
    var host: String = ""
    var port: Int = 22
    var keyType: String = ""
    var publicKeyBase64: String = ""
    var addedAt: Date = Date()

    init(host: String, port: Int, keyType: String, publicKeyBase64: String) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.publicKeyBase64 = publicKeyBase64
    }
}
