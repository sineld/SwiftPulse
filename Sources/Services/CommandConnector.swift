import Foundation
import NIOCore
import NIOPosix

/// Connects through a command whose stdin and stdout carry the SSH stream, like ssh_config's `ProxyCommand`
/// (`cloudflared access ssh --hostname %h`, `ssh -W %h:%p bastion`, …).
enum CommandConnector {
    enum CommandError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let why) = self { "ProxyCommand failed: \(why)" } else { nil } }
    }

    /// `%h` host, `%p` port, `%r` user, `%%` a percent sign, as ssh_config expands them.
    static func expand(_ command: String, host: String, port: Int, user: String) -> String {
        var out = ""
        var characters = command.makeIterator()
        while let c = characters.next() {
            guard c == "%", let token = characters.next() else { out.append(c); continue }
            switch token {
            case "h": out += host
            case "p": out += String(port)
            case "r": out += user
            case "%": out += "%"
            default: out += "%" + String(token)
            }
        }
        return out
    }

    static func connect(_ command: String, host: String, port: Int, user: String) async throws -> Channel {
        // Writing to a command that has exited raises SIGPIPE, which would end the app instead of the connection.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec " + expand(command, host: host, port: port, user: user)]
        // Not a login shell (anything a profile prints would corrupt the stream), so add where tools usually live.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CommandError.failed(error.localizedDescription) }

        // NIO takes its own copies; the Pipe handles are closed so only NIO and the command hold the pipes.
        let readFD = dup(output.fileHandleForReading.fileDescriptor), writeFD = dup(input.fileHandleForWriting.fileDescriptor)
        try? output.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        do {
            let channel = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .takingOwnershipOfDescriptors(input: readFD, output: writeFD).get()
            channel.closeFuture.whenComplete { _ in if process.isRunning { process.terminate() } }
            return channel
        } catch {
            process.terminate()
            close(readFD)
            close(writeFD)
            throw CommandError.failed(error.localizedDescription)
        }
    }
}
