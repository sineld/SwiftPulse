import Foundation
import SwiftData

/// Everything needed to open one SSH hop, resolved from models + secret store (plain data, no SwiftData refs).
struct ConnectionSpec: Sendable {
    var host: String
    var port: Int
    var username: String
    var privateKey: String?
    var passphrase: String?
    var password: String?
    var jumpHosts: [ConnectionSpec] = []
    var proxy: ProxySpec?
    var proxyCommand: String?
    /// Sign in with the "none" method: no password or key at all.
    var noAuthentication = false
    var timeout: TimeInterval = 15

    var label: String { "\(username)@\(host):\(port)" }

    enum SpecError: LocalizedError, Equatable {
        case noHost, noIdentity, identityWithoutCredentials(String), noCredentials, missingPrivateKey(String), missingJumpHost, jumpHostLoop
        var errorDescription: String? {
            switch self {
            case .noHost: "Enter a host name or IP address."
            case .noIdentity: "Select an identity."
            case .identityWithoutCredentials(let name): "Identity “\(name)” has neither a password nor an SSH key."
            case .noCredentials: "Enter a password or select an SSH key."
            case .missingPrivateKey(let name): "The private key of “\(name)” is not stored on this Mac. Import the key again."
            case .missingJumpHost: "A jump host referenced by this machine no longer exists."
            case .jumpHostLoop: "The jump host chain is too deep or loops back on itself."
            }
        }
    }

    /// Plain snapshot of the connection-relevant fields of a machine (saved or still being edited in a form).
    /// Built from values only, so producing a spec never touches the SwiftData store.
    struct Fields {
        var host: String
        var port: Int
        var authMethod: AuthMethod
        var identity: Identity?
        var username: String
        var sshKey: SSHKey?
        var proxy: Proxy?
        var jumpHostIDs: [UUID]
        var proxyCommand = ""
        /// Secret-store key of the machine's own password (nil for an unsaved form) …
        var passwordKey: String?
        /// … or the password typed into the form that is not saved yet.
        var enteredPassword: String?

        init(_ machine: Machine) {
            host = machine.host; port = machine.port; authMethod = machine.authMethod; identity = machine.identity
            username = machine.username; sshKey = machine.sshKey; proxy = machine.proxy
            jumpHostIDs = machine.useJumpHost ? machine.jumpHostIDs : []
            proxyCommand = machine.proxyCommand
            passwordKey = machine.passwordKey
        }

        init(host: String, port: Int, authMethod: AuthMethod, identity: Identity?, username: String, sshKey: SSHKey?,
             proxy: Proxy?, jumpHostIDs: [UUID], passwordKey: String? = nil, enteredPassword: String? = nil, proxyCommand: String = "") {
            self.host = host; self.port = port; self.authMethod = authMethod; self.identity = identity; self.username = username
            self.sshKey = sshKey; self.proxy = proxy; self.jumpHostIDs = jumpHostIDs; self.passwordKey = passwordKey; self.enteredPassword = enteredPassword
            self.proxyCommand = proxyCommand
        }
    }

    static func make(for machine: Machine, in context: ModelContext) throws -> ConnectionSpec {
        try make(Fields(machine), in: context)
    }

    /// Resolves fields (and the jump host chain) into a spec. Secrets are read from the secret store here.
    static func make(_ f: Fields, in context: ModelContext, depth: Int = 0) throws -> ConnectionSpec {
        guard depth < 5 else { throw SpecError.jumpHostLoop }
        let host = f.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw SpecError.noHost }
        var spec = ConnectionSpec(host: host, port: f.port, username: "")
        spec.timeout = TimeInterval(UserDefaults.standard.object(forKey: "connectionTimeout") as? Int ?? 15)

        func attach(_ key: SSHKey) throws {
            guard let pem = KeychainService.get(key.privateKeyKey), !pem.isEmpty else { throw SpecError.missingPrivateKey(key.name) }
            spec.privateKey = pem
            spec.passphrase = KeychainService.get(key.passphraseKey)
        }

        switch f.authMethod {
        case .identity:
            guard let identity = f.identity else { throw SpecError.noIdentity }
            spec.username = identity.username
            spec.password = identity.hasPassword ? KeychainService.get(identity.passwordKey) : nil
            if let key = identity.sshKey { try attach(key) }
            guard spec.password != nil || spec.privateKey != nil else { throw SpecError.identityWithoutCredentials(identity.name) }
        case .passwordOrKey:
            spec.username = f.username
            spec.password = f.enteredPassword?.nilIfEmpty ?? f.passwordKey.flatMap(KeychainService.get)
            if let key = f.sshKey { try attach(key) }
            guard spec.password != nil || spec.privateKey != nil else { throw SpecError.noCredentials }
        case .keyboardInteractive:
            // ponytail: NIOSSH has no keyboard-interactive; password auth covers the common PAM case.
            spec.username = f.username
            spec.password = f.enteredPassword?.nilIfEmpty ?? f.passwordKey.flatMap(KeychainService.get)
            guard spec.password != nil else { throw SpecError.noCredentials }
        case .noAuthentication:
            spec.username = f.username
            spec.noAuthentication = true
        }
        spec.proxyCommand = f.proxyCommand.trimmingCharacters(in: .whitespaces).nilIfEmpty

        if let proxy = f.proxy {
            spec.proxy = ProxySpec(host: proxy.host, port: proxy.port, kind: proxy.kind,
                                   username: proxy.auth == .usernamePassword ? proxy.username : nil,
                                   password: proxy.auth == .usernamePassword ? KeychainService.get(proxy.passwordKey) : nil)
        }

        for id in f.jumpHostIDs {
            let descriptor = FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })
            guard let hop = try context.fetch(descriptor).first else { throw SpecError.missingJumpHost }
            spec.jumpHosts.append(try make(Fields(hop), in: context, depth: depth + 1))
        }
        return spec
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
