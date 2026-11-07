import SwiftUI

enum SidebarItem: Hashable {
    case dashboard
    case machines, identities, sshKeys, proxies
    case snippets, docker, portForwarding
    case terminalSession(UUID), sftpSession(UUID), forwardingSession(UUID)
    case history(UUID)

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .machines: "Machines"
        case .identities: "Identities"
        case .sshKeys: "SSH Key"
        case .proxies: "Proxy"
        case .snippets: "Snippets"
        case .docker: "Docker"
        case .portForwarding: "Port Forwarding"
        case .terminalSession: "Terminal"
        case .sftpSession: "SFTP"
        case .forwardingSession: "Port Forwarding"
        case .history: "Session History"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .machines: "server.rack"
        case .identities: "person.badge.key"
        case .sshKeys: "key"
        case .proxies: "globe"
        case .snippets: "curlybraces"
        case .docker: "shippingbox"
        case .portForwarding: "arrow.left.arrow.right"
        case .terminalSession: "terminal"
        case .sftpSession: "folder"
        case .forwardingSession: "arrow.left.arrow.right.square"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum DisplayStyle: String, CaseIterable { case grid, list }
enum SortOrder: String, CaseIterable { case name, date }

@Observable
final class AppState {
    var selection: SidebarItem? = .machines
    var displayStyle: DisplayStyle = .grid
    var sortOrder: SortOrder = .name
    var hideHost = false
    var searchText = ""
}
