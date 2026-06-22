import Foundation
import HerdrKit

/// Top-level app state: owns the connection lifecycle and, once connected,
/// vends a `SessionModel` for the screens to read.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case disconnected
        case connecting(String)
        case connected(SessionModel)
        case failed(String)
    }

    var phase: Phase = .disconnected
    let connections = ConnectionStore()

    var isConnecting: Bool {
        if case .connecting = phase { return true }
        return false
    }

    /// Boot the app against in-memory sample data — the default entry point
    /// while the SSH transport is being completed.
    func connectDemo() async {
        await connect(label: "Demo · Mock data") {
            HerdrClient(transport: MockTransport())
        }
    }

    /// Connect to a saved host over SSH, bridging to its Herdr Unix socket.
    func connect(to host: Host) async {
        let credential = connections.credential(for: host)
        let connections = connections
        await connect(label: host.displayName) {
            HerdrClient(transport: SSHTransport(host: host, credential: credential) { key in
                Task { @MainActor in connections.pinHostKey(key, for: host) }
            })
        }
    }

    func disconnect() async {
        if case .connected(let session) = phase {
            await session.client.disconnect()
        }
        phase = .disconnected
    }

    private func connect(label: String, makeClient: () -> HerdrClient) async {
        phase = .connecting(label)
        let client = makeClient()
        do {
            try await client.connect()
            let session = SessionModel(client: client, label: label)
            await session.start()
            phase = .connected(session)
        } catch {
            phase = .failed(friendlyMessage(for: error))
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        switch error {
        case HerdrError.connectionFailed(let message): return message
        default: return String(describing: error)
        }
    }
}
