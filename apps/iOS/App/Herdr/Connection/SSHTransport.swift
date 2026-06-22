import Foundation
import Citadel
import Crypto // `Insecure` namespace + Curve25519
import NIOCore // `ByteBuffer`, `EventLoopPromise`
import NIOSSH // `NIOSSHPublicKey` + host-key validation delegate (TOFU pinning)
import HerdrKit

/// SSH-bridged transport to a remote Herdr Unix socket.
///
/// Herdr exposes no network port — its API is a local Unix domain socket
/// (`~/.config/herdr/herdr.sock`) — and it is **one-request-per-connection**:
/// the server closes the socket after each RPC reply; only `events.subscribe`
/// stays open to stream events. So each RPC opens its own short-lived SSH exec
/// channel that bridges stdio to the socket with `nc -U` (or `socat`), and
/// subscriptions get a dedicated long-lived channel. Host-key validation
/// currently accepts any key (TOFU pinning is a follow-up).
public actor SSHTransport: HerdrTransport {
    private let host: Host
    private let credential: Credential
    /// Called with the OpenSSH host-key string after a first successful connect,
    /// so the caller can pin it (TOFU). No-op for hosts already pinned.
    private let pinHostKey: @Sendable (String) -> Void

    private var client: SSHClient?
    private var socketPath: String?

    init(host: Host, credential: Credential, pinHostKey: @escaping @Sendable (String) -> Void = { _ in }) {
        self.host = host
        self.credential = credential
        self.pinHostKey = pinHostKey
    }

    // MARK: Lifecycle

    public func connect() async throws {
        guard client == nil else { return }
        guard !host.hostname.isEmpty, !host.username.isEmpty else {
            throw HerdrError.connectionFailed("This host is missing a hostname or username.")
        }

        let auth = try authenticationMethod()
        // TOFU host-key pinning: trust the key on first connect and remember it;
        // on later connects reject any key that doesn't match the pinned one.
        let knownKey = host.knownHostKey
        let recorder = HostKeyRecorder()
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: host.hostname,
                port: host.port,
                authenticationMethod: auth,
                hostKeyValidator: .custom(TOFUHostKeyValidator(expected: knownKey, recorder: recorder)),
                reconnect: .never
            )
        } catch {
            // A recorded key that differs from the pinned one means the validator
            // rejected it — surface that distinctly from a generic failure.
            if let seen = recorder.seenKey, let knownKey, seen != knownKey {
                throw HerdrError.connectionFailed(
                    "The SSH host key for \(host.displayName) has changed since you last connected. "
                    + "This can happen if the server was reinstalled — but it can also mean the "
                    + "connection is being intercepted. If you trust the change, remove and re-add this host."
                )
            }
            throw HerdrError.connectionFailed("Couldn't connect to \(host.displayName): \(error)")
        }
        // First successful connect: pin the key we just trusted.
        if knownKey == nil, let seen = recorder.seenKey { pinHostKey(seen) }

        // Resolve the socket path before publishing any state, so a discovery
        // failure can't leave the actor half-connected (client set, socketPath
        // nil) with the SSH session leaked.
        let resolved: String
        let override = host.socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            resolved = override
        } else {
            do {
                let found = try await discoverSocketPaths(client: client)
                guard let chosen = found.first else {
                    throw HerdrError.connectionFailed(
                        "Couldn't find a running Herdr socket on \(host.displayName) (looked under "
                        + "~/.config/herdr). Is Herdr running there?"
                    )
                }
                resolved = chosen
            } catch {
                try? await client.close()
                throw error
            }
        }
        self.client = client
        self.socketPath = resolved
    }

    public func disconnect() async {
        if let client { try? await client.close() }
        client = nil
        socketPath = nil
    }

    // MARK: Request / response (one-shot per connection)

    /// How long to wait for a one-shot reply before giving up. Herdr replies and
    /// closes immediately; this only guards against a wedged bridge/connection.
    private static let requestTimeout: Duration = .seconds(20)

    public func request(_ request: RPCRequest) async throws -> RPCResponse {
        guard let client, let socketPath else { throw HerdrError.notConnected }
        let command = Self.bridgeCommand(socketPath: socketPath)
        let frame = try NDJSON.frame(request)
        return try await withThrowingTaskGroup(of: RPCResponse.self) { group in
            group.addTask { try await Self.roundTrip(client: client, command: command, frame: frame) }
            group.addTask {
                try await Task.sleep(for: Self.requestTimeout)
                throw HerdrError.connectionFailed("The Herdr request timed out (no reply from the host).")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Open a one-shot bridge channel, send the request, and return the first
    /// decoded reply. The post-reply channel close is expected; a close with no
    /// reply preserves the underlying failure.
    private static func roundTrip(client: SSHClient, command: String, frame: Data) async throws -> RPCResponse {
        let collector = Collector()
        do {
            try await client.withExec(command) { inbound, outbound in
                try await outbound.write(ByteBuffer(bytes: frame))
                do {
                    for try await chunk in inbound {
                        guard case .stdout(let buffer) = chunk else { continue }
                        for line in collector.buffer.append(Self.data(buffer)) {
                            if collector.response == nil,
                               case .response(let response)? = try? IncomingMessage.decode(line: line) {
                                collector.response = response
                            }
                        }
                    }
                } catch {
                    collector.failure = error
                }
            }
        } catch {
            collector.failure = collector.failure ?? error
        }
        if let response = collector.response { return response }
        if let failure = collector.failure {
            throw HerdrError.connectionFailed(
                "The Herdr socket bridge failed: \(failure). Check that `nc` (or `socat`) is "
                + "available on the host and the socket path is correct."
            )
        }
        throw HerdrError.transportClosed
    }

    // MARK: Events (persistent subscription channel)

    public nonisolated func events(_ subscribeRequest: RPCRequest) -> AsyncStream<IncomingMessage> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self, let conn = await self.connection() else {
                    continuation.finish(); return
                }
                let command = Self.bridgeCommand(socketPath: conn.socketPath)
                let frame = (try? NDJSON.frame(subscribeRequest)) ?? Data()
                let collector = Collector()
                do {
                    try await conn.client.withExec(command) { inbound, outbound in
                        try await outbound.write(ByteBuffer(bytes: frame))
                        for try await chunk in inbound {
                            guard case .stdout(let buffer) = chunk else { continue }
                            for line in collector.buffer.append(Self.data(buffer)) {
                                if let message = try? IncomingMessage.decode(line: line) {
                                    continuation.yield(message)
                                }
                            }
                        }
                    }
                } catch {
                    // Subscription channel closed (disconnect / cancel / server).
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func connection() -> (client: SSHClient, socketPath: String)? {
        guard let client, let socketPath else { return nil }
        return (client, socketPath)
    }

    /// Accumulates bytes per channel and holds the first decoded reply.
    private final class Collector: @unchecked Sendable {
        var buffer = LineBuffer()
        var response: RPCResponse?
        var failure: Error?
    }

    /// Captures the host key the server presented, so `connect` can pin it after
    /// a first connect or distinguish a mismatch from a generic failure. Written
    /// on the handshake's event loop and read only after `connect` returns, so
    /// the access never races.
    private final class HostKeyRecorder: @unchecked Sendable {
        var seenKey: String?
    }

    /// Trust-on-first-use host-key validator. Records the presented key, then
    /// accepts it if nothing is pinned yet (`expected == nil`) or it matches the
    /// pinned key; otherwise rejects, so a changed key aborts the handshake.
    private struct TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
        let expected: String?
        let recorder: HostKeyRecorder

        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            let seen = String(openSSHPublicKey: hostKey)
            recorder.seenKey = seen
            if expected == nil || expected == seen {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HerdrError.connectionFailed("SSH host key mismatch."))
            }
        }
    }

    private static func data(_ buffer: ByteBuffer) -> Data {
        Data(buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? [])
    }

    // MARK: Helpers

    private func authenticationMethod() throws -> SSHAuthenticationMethod {
        switch host.authMethod {
        case .password:
            guard let password = credential.password, !password.isEmpty else {
                throw HerdrError.connectionFailed("No password saved for \(host.displayName).")
            }
            return .passwordBased(username: host.username, password: password)

        case .privateKey:
            guard let pem = credential.privateKey, !pem.isEmpty else {
                throw HerdrError.connectionFailed("No private key saved for \(host.displayName).")
            }
            let key = pem.trimmingCharacters(in: .whitespacesAndNewlines)
            let decryptionKey = credential.passphrase
                .flatMap { $0.isEmpty ? nil : $0 }
                .map { Data($0.utf8) }

            // OpenSSH-format keys (`BEGIN OPENSSH PRIVATE KEY`) can hold either an
            // ed25519 or RSA key; classic PEM (`BEGIN RSA PRIVATE KEY`) is RSA.
            // Try ed25519 first, then RSA, so any common key type works.
            if let ed = try? Curve25519.Signing.PrivateKey(sshEd25519: key, decryptionKey: decryptionKey) {
                return .ed25519(username: host.username, privateKey: ed)
            }
            do {
                let rsa = try Insecure.RSA.PrivateKey(sshRsa: key, decryptionKey: decryptionKey)
                return .rsa(username: host.username, privateKey: rsa)
            } catch {
                throw HerdrError.connectionFailed(
                    "Couldn't read this private key. Supported types are OpenSSH ed25519 and RSA"
                    + " — if the key is encrypted, add its passphrase, or use password auth."
                )
            }
        }
    }

    /// Probe the remote host for live Herdr sockets, most-preferred first. Mirrors
    /// Herdr's documented resolution order: `HERDR_SOCKET_PATH`, then the default
    /// session socket, then named sessions under `~/.config/herdr/sessions/<name>/`.
    /// Wrapped in `sh -c` (POSIX, any login shell) and ended with `; true` so the
    /// command always exits 0 — Citadel's `executeCommand` throws on non-zero exit,
    /// and an unmatched `sessions/*` glob makes the final `[ -S … ]` test fail.
    private func discoverSocketPaths(client: SSHClient) async throws -> [String] {
        let probe = #"sh -c 'for p in "$HERDR_SOCKET_PATH" "$HOME/.config/herdr/herdr.sock" "$HOME"/.config/herdr/sessions/*/herdr.sock; do [ -S "$p" ] && echo "$p"; done; true'"#
        let output: ByteBuffer
        do {
            output = try await client.executeCommand(probe)
        } catch {
            throw HerdrError.connectionFailed(
                "Couldn't search for the Herdr socket on \(host.displayName): \(error)"
            )
        }
        let text = output.getString(at: output.readerIndex, length: output.readableBytes) ?? ""
        var seen = Set<String>()
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Shell command run on the remote host to bridge stdio to the Herdr socket.
    /// A leading `~` is rewritten to `$HOME` so the remote shell expands it
    /// (tilde expansion doesn't fire mid-word, but `$HOME` does). For the
    /// one-shot model, `nc -U` is sufficient; `socat` is used if present.
    static func bridgeCommand(socketPath: String) -> String {
        // Build a shell-safe target. A leading `~` becomes an unquoted `"$HOME"`
        // (so the remote shell expands it); the remainder is single-quoted so an
        // override path can't inject shell syntax.
        let target: String
        if socketPath.hasPrefix("~") {
            target = "\"$HOME\"" + singleQuoted(String(socketPath.dropFirst()))
        } else {
            target = singleQuoted(socketPath)
        }
        return "socat - UNIX-CONNECT:\(target) || nc -U \(target)"
    }

    /// POSIX single-quote escaping: wrap in `'…'`, closing/escaping/reopening for
    /// any embedded single quote.
    private static func singleQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
