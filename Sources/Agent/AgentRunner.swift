import Foundation
import SwiftData
import Citadel
import NIOCore

/// One machine's result of an agent's command.
struct AgentRunResult: Codable, Equatable, Sendable {
    var host: String
    var hostID: String
    var exitCode: Int?
    var output: String
    /// The output was longer than the cap; its end is kept.
    var truncated: Bool
    /// Why there is no exit code: no credentials, unverified host key, could not connect, timed out.
    var error: String?
    var seconds: Double
}

/// Runs an agent's command on machines, a few at a time, over SwiftPulse's own connections and credentials:
/// the agent never sees them. Host keys are never auto-trusted here, whatever the settings say.
enum AgentRunner {
    static let outputCap = 1_000_000
    static let marker = "__SWIFTPULSE_EXIT__"

    /// `sh -c` with the command quoted; `sudo -n` never waits for a password. The exit code is printed after a
    /// marker rather than read from the channel, which reports nothing for a process killed by a signal.
    static func wrap(_ command: String, sudo: Bool) -> String {
        let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let run = sudo ? "sudo -n sh -c \(quoted)" : "sh -c \(quoted)"
        return "\(run) 2>&1; printf '\\n\(marker)%d\\n' $?"
    }

    /// Splits the marker off the output.
    static func parse(_ raw: String) -> (output: String, exitCode: Int?) {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = text.range(of: marker, options: .backwards) else { return (text, nil) }
        let code = Int(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        var output = String(text[..<range.lowerBound])
        if output.hasSuffix("\n") { output.removeLast() }
        return (output, code)
    }

    /// The last `cap` bytes of `data`, and whether anything was cut.
    static func tail(_ data: Data, cap: Int = outputCap) -> (String, Bool) {
        guard data.count > cap else { return (String(decoding: data, as: UTF8.self), false) }
        return (String(decoding: data.suffix(cap), as: UTF8.self), true)
    }

    @MainActor
    static func run(command: String, on machines: [Machine], sudo: Bool, timeout: TimeInterval, concurrency: Int,
                    container: ModelContainer, onResult: ((AgentRunResult) -> Void)? = nil) async -> [AgentRunResult] {
        let script = wrap(command, sudo: sudo)
        // Specs (and their secrets) are resolved here, on the main actor, and never leave this function.
        let jobs: [(name: String, id: String, spec: Result<ConnectionSpec, Error>)] = machines.map { machine in
            (machine.displayName, machine.id.uuidString, Result { try ConnectionSpec.make(for: machine, in: container.mainContext) })
        }
        let limit = max(1, min(concurrency, 32))
        return await withTaskGroup(of: (Int, AgentRunResult).self) { group in
            var results = [AgentRunResult?](repeating: nil, count: jobs.count)
            var next = 0
            func start(_ index: Int) {
                let job = jobs[index]
                group.addTask {
                    (index, await runOne(script: script, name: job.name, id: job.id, resolved: job.spec, timeout: timeout, container: container))
                }
            }
            while next < min(limit, jobs.count) { start(next); next += 1 }
            for await (index, result) in group {
                results[index] = result
                onResult?(result)
                if next < jobs.count { start(next); next += 1 }
            }
            return results.compactMap { $0 }
        }
    }

    private static func runOne(script: String, name: String, id: String, resolved: Result<ConnectionSpec, Error>,
                               timeout: TimeInterval, container: ModelContainer) async -> AgentRunResult {
        let started = Date()
        var result = AgentRunResult(host: name, hostID: id, exitCode: nil, output: "", truncated: false, error: nil, seconds: 0)
        guard !Task.isCancelled else {
            result.error = "Cancelled."
            return result
        }
        let spec: ConnectionSpec
        switch resolved {
        case .success(let value): spec = value
        case .failure(let error):
            result.error = error.localizedDescription
            return result
        }

        let refused = HostKeyRefusal()
        let client: SSHClient
        do {
            client = try await SSHService.connect(spec, container: container, autoTrust: false) { info in
                refused.info = info
                return false
            }
        } catch {
            if let info = refused.info {
                result.error = "host_key_unverified: \(info.host):\(info.port) offered a \(info.changed ? "changed" : "new") \(info.type) key "
                    + "(\(info.fingerprint)). Agents never trust host keys; connect once from SwiftPulse's terminal to check and trust it."
            } else {
                result.error = "Could not connect to \(spec.label): \(error.localizedDescription)"
            }
            result.seconds = Date().timeIntervalSince(started)
            return result
        }

        let collected = OutputBuffer()
        let finished: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    for try await chunk in try await client.executeCommandStream(script) {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer): collected.append(Data(buffer.readableBytesView))
                        }
                    }
                } catch {
                    collected.failure = error
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        try? await client.close()

        let (raw, cut) = tail(collected.data)
        let parsed = parse(raw)
        result.output = parsed.output
        result.exitCode = parsed.exitCode
        result.truncated = cut || collected.dropped
        if parsed.exitCode == nil {
            result.error = Task.isCancelled ? "Cancelled." : !finished ? "Timed out after \(Int(timeout)) s."
                : collected.failure.map { "The command failed: \($0.localizedDescription)" } ?? "The command ended without an exit code."
        }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    /// The key an agent's connection refused, for the error message.
    private final class HostKeyRefusal: @unchecked Sendable { var info: HostKeyInfo? }

    /// Output as it arrives, kept to twice the cap so a chatty command can't fill memory.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private(set) var dropped = false
        var failure: Error?

        func append(_ chunk: Data) {
            lock.withLock {
                bytes.append(chunk)
                if bytes.count > AgentRunner.outputCap * 2 {
                    bytes = bytes.suffix(AgentRunner.outputCap)
                    dropped = true
                }
            }
        }

        var data: Data { lock.withLock { bytes } }
    }
}
