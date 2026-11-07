import Foundation

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case identity, passwordOrKey, keyboardInteractive
    /// No password or key: the server trusts the connection itself (Tailscale SSH, an SSH CA via the network).
    case noAuthentication = "none"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .identity: "Identity"
        case .passwordOrKey: "Password or Key"
        case .keyboardInteractive: "Keyboard Interactive"
        case .noAuthentication: "None (Tailscale SSH)"
        }
    }
}

enum ConnectionKind: String, Codable, CaseIterable, Identifiable {
    case ssh, mosh
    var id: String { rawValue }
    var title: String { self == .ssh ? "SSH" : "Mosh" }
}

enum SSHKeyType: String, Codable, CaseIterable, Identifiable {
    case ed25519, ecdsaP256, ecdsaP384, ecdsaP521, rsa
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ed25519: "ed25519"
        case .ecdsaP256: "ECDSA P-256"
        case .ecdsaP384: "ECDSA P-384"
        case .ecdsaP521: "ECDSA P-521"
        case .rsa: "RSA"
        }
    }
}

enum ProxyKind: String, Codable, CaseIterable, Identifiable {
    case socks5, httpConnect
    var id: String { rawValue }
    var title: String { self == .socks5 ? "SOCKS5" : "HTTP CONNECT" }
}

enum ProxyAuth: String, Codable, CaseIterable, Identifiable {
    case none, usernamePassword
    var id: String { rawValue }
    var title: String { self == .none ? "None" : "Username Password" }
}

enum ForwardingMode: String, Codable, CaseIterable, Identifiable {
    case local, remote, dynamic
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case terminal, sftp, portForwarding
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: "SSH"
        case .sftp: "SFTP"
        case .portForwarding: "Port Forwarding"
        }
    }
}
