import Foundation
import SwiftData

/// Owns live terminal (and later SFTP / port-forwarding) sessions and writes Session History records.
@Observable @MainActor
final class SessionManager {
    private(set) var terminals: [TerminalSession] = []
    private(set) var sftps: [SFTPSession] = []
    private(set) var forwards: [ForwardingSession] = []
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    func openTerminal(_ machine: Machine, command: String? = nil, title: String? = nil) -> TerminalSession {
        let context = container.mainContext
        let username = machine.authMethod == .identity ? (machine.identity?.username ?? "") : machine.username
        let record = SessionRecord(kind: .terminal, machine: machine, username: username)
        context.insert(record)
        let session = TerminalSession(machine: machine, record: record, container: container)
        session.initialCommand = command
        if let title { session.title = title }
        terminals.append(session)
        return session
    }

    func terminal(_ id: UUID) -> TerminalSession? { terminals.first { $0.id == id } }

    func openSFTP(_ machine: Machine, path: String? = nil) -> SFTPSession {
        let context = container.mainContext
        let username = machine.authMethod == .identity ? (machine.identity?.username ?? "") : machine.username
        let record = SessionRecord(kind: .sftp, machine: machine, username: username)
        context.insert(record)
        let session = SFTPSession(machine: machine, record: record, container: container, path: path)
        sftps.append(session)
        return session
    }

    func sftp(_ id: UUID) -> SFTPSession? { sftps.first { $0.id == id } }

    @discardableResult
    func startForwarding(_ rule: PortForwardingRule) -> ForwardingSession? {
        if let existing = forwards.first(where: { $0.rule.id == rule.id }) { return existing }
        let context = container.mainContext
        guard let machineID = rule.machineID,
              let machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == machineID })).first else { return nil }
        let username = machine.authMethod == .identity ? (machine.identity?.username ?? "") : machine.username
        let record = SessionRecord(kind: .portForwarding, machine: machine, username: username)
        context.insert(record)
        let session = ForwardingSession(rule: rule, machine: machine, record: record, container: container)
        forwards.append(session)
        return session
    }

    func forwarding(_ id: UUID) -> ForwardingSession? { forwards.first { $0.id == id } }
    func forwarding(for rule: PortForwardingRule) -> ForwardingSession? { forwards.first { $0.rule.id == rule.id } }

    func close(_ session: ForwardingSession) {
        session.stop()
        forwards.removeAll { $0.id == session.id }
    }

    /// Live sessions belonging to one machine (terminal, SFTP and tunnels).
    func sessionCount(for machine: Machine) -> Int {
        terminals.filter { $0.machine.id == machine.id }.count
            + sftps.filter { $0.machine.id == machine.id }.count
            + forwards.filter { $0.machine.id == machine.id }.count
    }

    /// Closes them, so deleting a machine cannot leave an orphaned connection behind.
    func closeSessions(for machine: Machine) {
        terminals.filter { $0.machine.id == machine.id }.forEach { close($0) }
        sftps.filter { $0.machine.id == machine.id }.forEach { close($0) }
        forwards.filter { $0.machine.id == machine.id }.forEach { close($0) }
    }

    /// Starts every rule flagged Auto Start (called once when the main window appears).
    func autoStartForwarding() {
        let rules = (try? container.mainContext.fetch(FetchDescriptor<PortForwardingRule>(predicate: #Predicate { $0.autoStart }))) ?? []
        rules.forEach { startForwarding($0) }
    }

    func close(_ session: SFTPSession) {
        session.close()
        sftps.removeAll { $0.id == session.id }
    }

    func close(_ session: TerminalSession) {
        session.close()
        terminals.removeAll { $0.id == session.id }
    }
}
