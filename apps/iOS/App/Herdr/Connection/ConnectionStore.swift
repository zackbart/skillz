import Foundation

/// Persists saved hosts (non-secret fields in `UserDefaults`) and brokers their
/// secrets through the Keychain.
@MainActor
@Observable
final class ConnectionStore {
    private(set) var hosts: [Host] = []

    private let defaultsKey = "herdr.hosts.v1"
    private let keychain = KeychainStore(service: "dev.herdr.client")

    init() {
        load()
    }

    /// Add or update a host. `secret` is the private key or password to stash in
    /// the Keychain (pass `nil` to leave any existing secret untouched).
    func upsert(_ host: Host, secret: String?) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        persist()
        if let secret, !secret.isEmpty {
            keychain.set(secret, account: host.id.uuidString)
        }
    }

    func remove(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        persist()
        keychain.delete(account: host.id.uuidString)
    }

    /// Record the SSH host key trusted on first connect (TOFU). Persists so later
    /// connections can detect a changed key. No-op if the host is gone or already
    /// pinned to this key.
    func pinHostKey(_ key: String, for host: Host) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }),
              hosts[index].knownHostKey != key else { return }
        hosts[index].knownHostKey = key
        persist()
    }

    func credential(for host: Host) -> Credential {
        let secret = keychain.get(account: host.id.uuidString)
        switch host.authMethod {
        case .password:
            return Credential(password: secret)
        case .privateKey:
            return Credential(privateKey: secret)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Host].self, from: data) else { return }
        hosts = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
