import Foundation

/// How we authenticate the SSH connection to a host.
enum AuthMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case privateKey
    case password

    var id: String { rawValue }
    var title: String {
        switch self {
        case .privateKey: return "Private key"
        case .password: return "Password"
        }
    }
}

/// A saved SSH connection to a machine running Herdr. Non-secret fields are
/// persisted in `UserDefaults`; the secret (key or password) lives in the
/// Keychain keyed by `id`.
struct Host: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var nickname: String = ""
    var hostname: String = ""
    var port: Int = 22
    var username: String = ""
    var authMethod: AuthMethod = .privateKey
    /// Optional override for the remote Herdr socket. Blank = auto-detect on
    /// connect: the default session (`~/.config/herdr/herdr.sock`), or the sole
    /// running session under `~/.config/herdr/sessions/<n>/`. Set this only to
    /// target a specific named session or a non-standard path.
    var socketPath: String = ""
    /// The SSH host key trusted on first connect (TOFU), as an OpenSSH
    /// `"algo base64"` string. Non-secret. `nil` until the first successful
    /// connection pins it; later connects reject a key that doesn't match.
    var knownHostKey: String?

    var displayName: String {
        nickname.isEmpty ? "\(username)@\(hostname)" : nickname
    }

    var subtitle: String {
        "\(username)@\(hostname):\(port)"
    }
}

/// The secret material for a host, fetched from the Keychain at connect time.
struct Credential: Sendable {
    var password: String?
    var privateKey: String?
    var passphrase: String?
}
