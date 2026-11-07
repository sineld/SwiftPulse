import AppKit
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH
import SwiftData

/// One interactive SSH shell rendered by SwiftTerm.
@Observable @MainActor
final class TerminalSession: Identifiable {
    enum State: Equatable { case connecting, running, closed(String?) }

    let id = UUID()
    let machine: Machine
    let record: SessionRecord
    private(set) var state: State = .connecting
    var title: String
    let terminalView: TerminalView
    private let container: ModelContainer
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var outbound: Task<Void, Never>?   // serial chain so keystrokes keep their order
    private var reconnecting: Task<Void, Never>?
    /// Typed into the shell once it first runs (e.g. `docker exec -it …`); not again after a reconnect.
    var initialCommand: String?
    /// The shell's working directory, when it reports one (OSC 7: shell integration, or a shell that does it itself).
    private(set) var currentDirectory: String?

    nonisolated static let shellIntegrationKey = "terminalShellIntegration"
    /// One line for bash and zsh that reports the directory at every prompt (OSC 7), then clears the screen. The
    /// leading space keeps it out of bash's history (HISTCONTROL=ignorespace, Ubuntu's default).
    nonisolated static let shellIntegration = #" if [ -n "$ZSH_VERSION" ]; then _sp_cwd() { printf '\033]7;file://%s%s\007' "$HOST" "$PWD"; }; precmd_functions+=(_sp_cwd); elif [ -n "$BASH_VERSION" ]; then _sp_cwd() { printf '\033]7;file://%s%s\007' "$HOSTNAME" "$PWD"; }; PROMPT_COMMAND="_sp_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"; fi; clear"#

    /// The path in an OSC 7 report, `file://host/path` (the path may be percent-encoded, or not, with spaces).
    nonisolated static func directory(fromOSC7 report: String) -> String? {
        guard report.hasPrefix("file://") else { return report.hasPrefix("/") ? report : nil }
        let rest = report.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = String(rest[slash...])
        return path.removingPercentEncoding ?? path
    }
    /// Reconnects tried since the session last ran.
    private var attempts = 0
    nonisolated static let maxAttempts = 3
    static let reconnectDelay: TimeInterval = 10
    private let bridge = Bridge()

    var stateText: String {
        switch state {
        case .connecting: "SSH · Connecting"
        case .running: "SSH · Running"
        case .closed(let why): why.map { "SSH · \($0)" } ?? "SSH · Closed"
        }
    }

    init(machine: Machine, record: SessionRecord, container: ModelContainer) {
        self.machine = machine
        self.record = record
        self.container = container
        self.title = machine.displayName
        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        TerminalTheme.apply(to: terminalView)
        bridge.session = self
        terminalView.terminalDelegate = bridge
        connect()
    }

    func connect() {
        task?.cancel()
        state = .connecting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let spec = try ConnectionSpec.make(for: machine, in: ModelContext(container))
                let client = try await SSHService.connect(spec, container: container)
                self.client = client
                let t = terminalView.getTerminal()
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true, term: "xterm-256color",
                    terminalCharacterWidth: t.cols, terminalRowHeight: t.rows,
                    terminalPixelWidth: Int(terminalView.frame.width), terminalPixelHeight: Int(terminalView.frame.height),
                    terminalModes: SSHTerminalModes([:]))
                try await client.withPTY(request) { inbound, outbound in
                    await MainActor.run {
                        self.writer = outbound; self.state = .running; self.attempts = 0
                        // A new shell each time, so the hook goes in on reconnects too.
                        if UserDefaults.standard.bool(forKey: Self.shellIntegrationKey) { self.send(text: Self.shellIntegration + "\n") }
                        if let command = self.initialCommand {
                            self.initialCommand = nil
                            self.send(text: command + "\n")
                        }
                    }
                    for try await chunk in inbound {
                        let bytes: [UInt8]
                        switch chunk {
                        case .stdout(let b), .stderr(let b): bytes = Array(b.readableBytesView)
                        }
                        await MainActor.run { self.terminalView.feed(byteArray: bytes[...]) }
                    }
                }
                await MainActor.run { self.finish(nil) }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return self.finish(nil) }
                    let wasRunning = self.state == .running
                    self.finish(error.localizedDescription)
                    if Self.shouldReconnect(after: error, wasRunning: wasRunning, attempts: self.attempts) { self.scheduleReconnect() }
                }
            }
        }
    }

    /// A shell that was running and dropped (network, sleep, server restart) comes back by itself, a few times.
    /// Not after the user's own exit (no error), a first connection that never worked, or a refused sign-in or host
    /// key, which retrying can't fix.
    nonisolated static func shouldReconnect(after error: Error, wasRunning: Bool, attempts: Int) -> Bool {
        guard wasRunning || attempts > 0, attempts < maxAttempts else { return false }
        if error is SSHService.ConnectError || error is ConnectionSpec.SpecError { return false }
        if let client = error as? SSHClientError, case .allAuthenticationOptionsFailed = client { return false }
        return true
    }

    private func scheduleReconnect() {
        attempts += 1
        terminalView.feed(text: "\u{1b}[90m[Reconnecting in \(Int(Self.reconnectDelay)) s, attempt \(attempts) of \(Self.maxAttempts)…]\u{1b}[0m\r\n")
        reconnecting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.reconnectDelay))
            guard !Task.isCancelled, let self, case .closed = self.state else { return }
            let c = self.client; self.client = nil; self.writer = nil
            Task { try? await c?.close() }
            self.connect()
        }
    }

    func restart() {
        reconnecting?.cancel(); attempts = 0
        let c = client; client = nil; writer = nil
        Task { try? await c?.close() }
        terminalView.getTerminal().resetToInitialState()
        connect()
    }

    func close() {
        reconnecting?.cancel(); attempts = Self.maxAttempts
        task?.cancel()
        let c = client; client = nil; writer = nil
        Task { try? await c?.close() }
        finish(nil)
    }

    private func finish(_ error: String?) {
        guard state != .closed(error) else { return }
        state = .closed(error)
        record.lastActiveAt = .now
        if let error { terminalView.feed(text: "\r\n\u{1b}[31m[\(error)]\u{1b}[0m\r\n") }
        else { terminalView.feed(text: "\r\n\u{1b}[90m[Session closed]\u{1b}[0m\r\n") }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let writer else { return }
        let buffer = ByteBuffer(bytes: bytes)
        outbound = Task { [previous = outbound] in
            await previous?.value
            try? await writer.write(buffer)
        }
    }

    func send(text: String) { send(ArraySlice(Array(text.utf8))) }

    func resize(cols: Int, rows: Int) {
        guard let writer else { return }
        let w = Int(terminalView.frame.width), h = Int(terminalView.frame.height)
        outbound = Task { [previous = outbound] in
            await previous?.value
            try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: w, pixelHeight: h)
        }
    }

    /// SwiftTerm delegate (non-isolated object; hops to the session on the main actor).
    private final class Bridge: NSObject, TerminalViewDelegate {
        weak var session: TerminalSession?
        func send(source: TerminalView, data: ArraySlice<UInt8>) { MainActor.assumeIsolated { session?.send(data) } }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { MainActor.assumeIsolated { session?.resize(cols: newCols, rows: newRows) } }
        func setTerminalTitle(source: TerminalView, title: String) { MainActor.assumeIsolated { if !title.isEmpty { session?.title = title } } }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            MainActor.assumeIsolated { session?.currentDirectory = directory.flatMap(TerminalSession.directory(fromOSC7:)) }
        }
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
        func bell(source: TerminalView) { if UserDefaults.standard.object(forKey: "terminalBell") as? Bool ?? true { NSSound.beep() } }
        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
