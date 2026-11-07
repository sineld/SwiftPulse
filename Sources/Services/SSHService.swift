import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto
import SwiftData
import AppKit

/// Opens Citadel SSH clients for a `ConnectionSpec`: auth fallback (key → password), host key trust store, jump host chain.
enum SSHService {
    enum ConnectError: LocalizedError {
        case hostKeyRejected, badPrivateKey(String), timedOut, failed(String)
        var errorDescription: String? {
            switch self {
            case .hostKeyRejected: "Host key was rejected."
            case .badPrivateKey(let why): "Private key could not be used: \(why)"
            case .timedOut: "Connection timed out."
            case .failed(let why): why
            }
        }
    }

    /// Connects through the jump host chain. Unknown host keys are surfaced via `confirmHostKey`
    /// *after* the failed attempt (Citadel's 10 s login timeout would expire if we prompted mid-handshake), then retried.
    /// `autoTrust: false` ignores "Always Trust Host Keys", so an agent's run never trusts a key nobody looked at.
    static func connect(_ spec: ConnectionSpec, container: ModelContainer, autoTrust: Bool = true,
                        confirmHostKey: @escaping (HostKeyInfo) async -> Bool = defaultConfirm) async throws -> SSHClient {
        var client: SSHClient?
        for hop in spec.jumpHosts + [spec] {
            var attempts = 0
            while true {
                attempts += 1
                let settings = try makeSettings(hop, container: container, autoTrust: autoTrust)
                do {
                    client = try await wrap(hop) {
                        if let previous = client { return try await previous.jump(to: settings) }
                        if let command = hop.proxyCommand {
                            let channel = try await CommandConnector.connect(command, host: hop.host, port: hop.port, user: hop.username)
                            return try await connect(on: channel, settings: settings)
                        }
                        if let proxy = hop.proxy {
                            let channel = try await ProxyConnector.connect(through: proxy, to: (hop.host, hop.port), timeout: hop.timeout)
                            return try await connect(on: channel, settings: settings)
                        }
                        return try await SSHClient.connect(to: settings)
                    }
                    break
                } catch let unknown as HostKeyUnknown where attempts < 3 {
                    guard await confirmHostKey(unknown.info) else { throw ConnectError.hostKeyRejected }
                    await HostKeyStore.trust(unknown.info, container: container)
                }
            }
        }
        return client!
    }

    /// Citadel's `connect(on:)` adds its handlers synchronously, which NIO allows only on the channel's own event
    /// loop (debug builds trap otherwise). The proxy and ProxyCommand paths hand it a channel made elsewhere, so the
    /// call runs with that loop as its task executor.
    private static func connect(on channel: Channel, settings: SSHClientSettings) async throws -> SSHClient {
        try await withTaskExecutorPreference(EventLoopExecutor(channel.eventLoop)) {
            try await SSHClient.connect(on: channel, settings: settings)
        }
    }

    private final class EventLoopExecutor: TaskExecutor, @unchecked Sendable {
        let loop: EventLoop
        init(_ loop: EventLoop) { self.loop = loop }
        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            loop.execute { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        }
    }

    @MainActor static func defaultConfirm(_ info: HostKeyInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = info.changed ? "Host key for \(info.host) has changed" : "Unknown host \(info.host):\(info.port)"
        alert.informativeText = (info.changed
            ? "The server presented a different \(info.type) key than the one saved earlier. This could indicate a man-in-the-middle attack.\n\n"
                + (info.savedFingerprint.map { "Saved:\n\($0)\n\nOffered:\n" } ?? "Offered:\n")
            : "The authenticity of this host can't be established.\n\n\(info.type) fingerprint:\n") + info.fingerprint
        alert.alertStyle = info.changed ? .critical : .warning
        alert.addButton(withTitle: info.changed ? "Trust New Key" : "Trust")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quick reachability + auth check used by "Test Connection".
    static func test(_ spec: ConnectionSpec, container: ModelContainer) async throws -> String {
        let client = try await connect(spec, container: container)
        defer { Task { try? await client.close() } }
        let out = try await client.executeCommand("uname -sr; hostname", maxResponseSize: 4096)
        return String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wrap(_ hop: ConnectionSpec, _ body: () async throws -> SSHClient) async throws -> SSHClient {
        do { return try await body() }
        catch let error as HostKeyUnknown { throw error }
        catch let error as ConnectError { throw error }
        catch let error as ChannelError {
            debugLog("[ssh] channel error \(error)")
            if case .connectTimeout = error { throw ConnectError.timedOut }
            throw ConnectError.failed("Could not connect to \(hop.label): \(error)")
        }
        catch {
            let text = String(reflecting: error)
            debugLog("[ssh] error \(text)")
            if text.contains("allAuthenticationOptionsFailed") { throw ConnectError.failed("Authentication failed for \(hop.label).") }
            throw ConnectError.failed("Could not connect to \(hop.label): \(text)")
        }
    }

    private static func makeSettings(_ spec: ConnectionSpec, container: ModelContainer, autoTrust: Bool) throws -> SSHClientSettings {
        // Note: RSASHA256 is deliberately NOT registered as a global algorithm; it is only used to sign userauth requests.
        var offers: [NIOSSHUserAuthenticationOffer] = []
        if let key = spec.privateKey, !key.isEmpty {
            do {
                let priv = try OpenSSHPrivateKey.privateKey(key, passphrase: spec.passphrase)
                offers.append(NIOSSHUserAuthenticationOffer(username: spec.username, serviceName: "", offer: .privateKey(.init(privateKey: priv))))
            } catch { if spec.password == nil { throw ConnectError.badPrivateKey(error.localizedDescription) } }
        }
        if let password = spec.password, !password.isEmpty {
            offers.append(NIOSSHUserAuthenticationOffer(username: spec.username, serviceName: "", offer: .password(.init(password: password))))
        }
        if spec.noAuthentication { offers = [NIOSSHUserAuthenticationOffer(username: spec.username, serviceName: "", offer: .none)] }
        let chain = AuthChain(offers: offers)
        var settings = SSHClientSettings(
            host: spec.host, port: spec.port,
            authenticationMethod: { .custom(chain) },
            hostKeyValidator: .custom(HostKeyStore(host: spec.host, port: spec.port, container: container, autoTrust: autoTrust))
        )
        settings.algorithms = .all
        settings.connectTimeout = .seconds(Int64(spec.timeout))
        return settings
    }
}

/// Tries each offer in order (key first, then password); NIOSSH calls back for the next one after a failure.
final class AuthChain: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private var offers: [NIOSSHUserAuthenticationOffer]
    init(offers: [NIOSSHUserAuthenticationOffer]) { self.offers = offers }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        while !offers.isEmpty {
            let offer = offers.removeFirst()
            switch offer.offer {
            case .privateKey where availableMethods.contains(.publicKey), .password where availableMethods.contains(.password), .none:
                nextChallengePromise.succeed(offer); return
            default: continue // server does not allow this method; skip to the next offer
            }
        }
        nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
    }
}

struct HostKeyInfo: Sendable {
    let host: String, port: Int, type: String, fingerprint: String, blobBase64: String, changed: Bool
    /// The fingerprint of the key saved earlier, when the offered one differs from it.
    var savedFingerprint: String?
}
struct HostKeyUnknown: Error { let info: HostKeyInfo }

/// Known-hosts check backed by SwiftData. Unknown or changed keys fail fast with `HostKeyUnknown`
/// unless "Always Trust Host Keys" is on; the caller confirms and calls `trust` before retrying.
final class HostKeyStore: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String; let port: Int; let container: ModelContainer; let autoTrust: Bool
    init(host: String, port: Int, container: ModelContainer, autoTrust: Bool = true) {
        self.host = host; self.port = port; self.container = container; self.autoTrust = autoTrust
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let (type, blob) = Self.serialize(hostKey)
        let info = HostKeyInfo(host: host, port: port, type: type, fingerprint: Self.fingerprint(blob), blobBase64: blob.base64EncodedString(), changed: false)
        Task { @MainActor [container, autoTrust] in
            let known = Self.known(host: info.host, port: info.port, in: ModelContext(container))
            switch Self.decide(offered: info.blobBase64, known: known.map(\.publicKeyBase64), autoTrust: autoTrust,
                               alwaysTrust: UserDefaults.standard.bool(forKey: "alwaysTrustHostKeys")) {
            case .accept:
                validationCompletePromise.succeed(())
            case .trust:
                await Self.trust(info, container: container)
                validationCompletePromise.succeed(())
            case .ask(let changed):
                var asked = HostKeyInfo(host: info.host, port: info.port, type: info.type, fingerprint: info.fingerprint,
                                        blobBase64: info.blobBase64, changed: changed)
                asked.savedFingerprint = known.first.flatMap { Data(base64Encoded: $0.publicKeyBase64) }.map(Self.fingerprint)
                validationCompletePromise.fail(HostKeyUnknown(info: asked))
            }
        }
    }

    enum Decision: Equatable { case accept, trust, ask(changed: Bool) }

    /// A saved key is accepted. "Always Trust Host Keys" covers hosts seen for the first time only: a key that
    /// differs from the saved one is always shown to the user, since that is what a man in the middle looks like.
    static func decide(offered: String, known: [String], autoTrust: Bool, alwaysTrust: Bool) -> Decision {
        if known.contains(offered) { return .accept }
        if known.isEmpty, autoTrust, alwaysTrust { return .trust }
        return .ask(changed: !known.isEmpty)
    }

    static func fingerprint(_ blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    @MainActor static func known(host: String, port: Int, in context: ModelContext) -> [KnownHostKey] {
        (try? context.fetch(FetchDescriptor<KnownHostKey>(predicate: #Predicate { $0.host == host && $0.port == port }))) ?? []
    }

    @MainActor static func trust(_ info: HostKeyInfo, container: ModelContainer) {
        let context = ModelContext(container)
        known(host: info.host, port: info.port, in: context).forEach(context.delete)
        context.insert(KnownHostKey(host: info.host, port: info.port, keyType: info.type, publicKeyBase64: info.blobBase64))
        try? context.save()
    }

    /// (algorithm name, raw key blob as sent on the wire: string type + key fields)
    static func serialize(_ key: NIOSSHPublicKey) -> (String, Data) {
        var buffer = ByteBuffer()
        _ = key.write(to: &buffer)
        let blob = Data(buffer.readableBytesView)
        var typeBuf = ByteBuffer(data: blob)
        let len = Int(typeBuf.readInteger(as: UInt32.self) ?? 0)
        let type = typeBuf.readString(length: len) ?? "unknown"
        return (type, blob)
    }
}

/// Unbuffered stderr logging for development (visible when the binary is launched from a shell).
func debugLog(_ message: String) {
    AppLog.shared.add(message)
    #if DEBUG
    FileHandle.standardError.write(Data((message + "\n").utf8))
    #endif
}
