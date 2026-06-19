import Foundation

/// In-memory, session-only store of remote passwords keyed by ssh target. Populated when
/// the user is prompted (key auth failed); never written to disk or Keychain, and cleared
/// when the host is deselected/removed or the app quits. RemoteHostIO reads it per call.
enum RemoteCredentials {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var store: [String: String] = [:]

    static func password(for target: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[target]
    }
    static func set(_ password: String, for target: String) {
        lock.lock(); defer { lock.unlock() }
        store[target] = password
    }
    static func clear(_ target: String) {
        lock.lock(); defer { lock.unlock() }
        store[target] = nil
    }
}

/// The outcome of a connectivity probe — drives the "prompt for password" flow.
enum ConnectResult: Equatable {
    case ok                 // authenticated (key, or a previously-entered password)
    case needsPassword      // reachable but auth was refused → ask the user
    case failed(String)     // unreachable / DNS / timeout / other — show the message
}

/// `HostIO` over the user's own `ssh` (already configured with their keys / `~/.ssh/config`
/// / `known_hosts`), so Loadout scans a remote machine with the same scanner code as local.
///
/// **Auth.** Key-based by default (`BatchMode=yes`, never blocks). If no key works, the UI
/// prompts for a password (held only in `RemoteCredentials` for the session); password auth
/// is delivered to ssh via `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` (no `sshpass`
/// dependency, no controlling tty needed). The password reaches the helper through a child
/// env var (`LOADOUT_SSH_PASSWORD`) — never on disk.
/// // ponytail: the password is in the ssh process's environment during connect, so it's
/// //           visible to the same user via `ps -E`. Acceptable for a single-user desktop;
/// //           tighten to an fd-passed secret only if that threat model ever matters.
///
/// **Performance.** A multiplexed ControlMaster socket means the first call pays the
/// TCP+auth handshake and every later `ssh` reuses it over a new channel.
///
/// READ-ONLY: implements only the read/run surface of `HostIO` (see D7). `final class` +
/// `NSLock` because resolved `home`/`xdg` are cached once.
final class RemoteHostIO: HostIO, @unchecked Sendable {
    private let target: String          // "user@host" or an ~/.ssh/config alias
    private let sshPath = "/usr/bin/ssh"
    private let controlPath: String

    private let lock = NSLock()
    private var cachedHome: URL?
    private var cachedXDG: URL?

    init(target: String) {
        self.target = target
        let tag = String(UInt(bitPattern: target.hashValue), radix: 36).prefix(12)
        // Short ControlPath under ~/.ssh to stay under the 104-byte AF_UNIX `sun_path` limit.
        controlPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".ssh/loadout-cm-\(tag)")
    }

    // MARK: - Connectivity probe

    /// Try to reach the host with whatever auth is currently available (key, or a password
    /// already entered this session). Used before scanning so the UI can prompt on refusal.
    func connect() -> ConnectResult {
        let r = ssh("true")
        return Self.classifyConnect(exit: r.exit, stderr: String(decoding: r.stderr, as: UTF8.self))
    }

    /// Classify a probe result (pure — unit-tested). Auth refusal ⇒ needsPassword; anything
    /// else non-zero ⇒ failed with the ssh message.
    static func classifyConnect(exit: Int32, stderr: String) -> ConnectResult {
        if exit == 0 { return .ok }
        let s = stderr.lowercased()
        if s.contains("permission denied") || s.contains("publickey")
            || s.contains("authentication failed") || s.contains("no more authentication methods") {
            return .needsPassword
        }
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(msg.isEmpty ? "Could not connect (ssh exit \(exit))." : msg)
    }

    // MARK: - HostIO

    var home: URL {
        lock.lock(); defer { lock.unlock() }
        if let cachedHome { return cachedHome }
        let h = firstLine(ssh("printf %s \"$HOME\"").stdout)
        let url = URL(fileURLWithPath: h.isEmpty ? "/" : h)
        cachedHome = url
        return url
    }

    var xdgConfigHome: URL {
        lock.lock(); defer { lock.unlock() }
        if let cachedXDG { return cachedXDG }
        let x = firstLine(ssh("printf %s \"${XDG_CONFIG_HOME:-$HOME/.config}\"").stdout)
        let url = URL(fileURLWithPath: x.isEmpty ? "/.config" : x)
        cachedXDG = url
        return url
    }

    func exists(_ path: String) -> Bool {
        ssh("test -e \(q(path))").exit == 0
    }

    func readFile(_ path: String) throws -> Data {
        let r = ssh("cat -- \(q(path))")
        guard r.exit == 0 else {
            throw HostIOError.io(String(decoding: r.stderr, as: UTF8.self))
        }
        return r.stdout
    }

    func listDir(_ path: String) throws -> [DirEntry] {
        // One round-trip: a POSIX sh snippet emits delimited records (unit-sep \037 between
        // fields, record-sep \036 between entries) so filenames with spaces/newlines survive.
        // `for f in *` skips dotfiles (matches local `.skipsHiddenFiles`); isSymlink via `-L`
        // (entry's own type), isDir via `-d` (FOLLOWS links, matching local resourceValues).
        // ponytail: assumes a POSIX shell + readlink on the remote (true for macOS/Linux);
        //           a remote without them yields an empty listing → "no skills".
        let script = "cd -- \(q(path)) 2>/dev/null || exit 0; "
            + "for f in *; do [ -e \"$f\" ] || [ -L \"$f\" ] || continue; "
            + "if [ -L \"$f\" ]; then sl=1; lt=$(readlink \"$f\"); else sl=0; lt=; fi; "
            + "if [ -d \"$f\" ]; then d=1; else d=0; fi; "
            + "printf '%s\\037%s\\037%s\\037%s\\036' \"$f\" \"$d\" \"$sl\" \"$lt\"; done"
        let r = ssh(script)
        guard r.exit == 0 else {
            throw HostIOError.io(String(decoding: r.stderr, as: UTF8.self))
        }
        return Self.parseListDir(r.stdout)
    }

    func realpath(_ path: String) -> String {
        let r = ssh("realpath \(q(path)) 2>/dev/null || readlink -f \(q(path)) 2>/dev/null")
        let resolved = firstLine(r.stdout)
        return resolved.isEmpty ? path : resolved
    }

    func run(_ argv: [String], cwd: String?, stdin: Data?) -> (exit: Int32, stdout: Data, stderr: Data) {
        let prefix = cwd.map { "cd -- \(q($0)) && " } ?? ""
        let remote = prefix + argv.map(q).joined(separator: " ")
        return ssh(remote, stdin: stdin)
    }

    // MARK: - Parsing (pure — unit-tested without a live host)

    /// Parse the delimited `listDir` output into entries. Records split on \036, fields on
    /// \037: name, isDir(0/1), isSymlink(0/1), linkTarget.
    static func parseListDir(_ data: Data) -> [DirEntry] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\u{1E}", omittingEmptySubsequences: true).compactMap { rec in
            let f = rec.components(separatedBy: "\u{1F}")
            guard f.count == 4 else { return nil }
            let isSymlink = f[2] == "1"
            return DirEntry(
                name: f[0],
                isDir: f[1] == "1",
                isSymlink: isSymlink,
                linkTarget: isSymlink && !f[3].isEmpty ? f[3] : nil
            )
        }
    }

    // MARK: - ssh plumbing

    /// One `ssh` invocation against the multiplexed master. `remote` is run by the remote
    /// login shell; callers quote untrusted paths with `q`. Uses key auth unless a session
    /// password is set for this target, in which case SSH_ASKPASS delivers it.
    private func ssh(_ remote: String, stdin: Data? = nil) -> (exit: Int32, stdout: Data, stderr: Data) {
        let password = RemoteCredentials.password(for: target)
        let argv = [sshPath] + Self.baseArgs(controlPath: controlPath, password: password != nil)
            + [target, remote]
        var env: [String: String]?
        if let password {
            env = [
                "SSH_ASKPASS": Self.askpassPath,
                "SSH_ASKPASS_REQUIRE": "force",
                "LOADOUT_SSH_PASSWORD": password,
            ]
        }
        return spawnProcess(argv, cwd: nil, stdin: stdin, env: env)
    }

    private static func baseArgs(controlPath: String, password: Bool) -> [String] {
        var args = ["-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=10",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPersist=300",
                    "-o", "ControlPath=\(controlPath)"]
        if password {
            // Password mode: BatchMode would disable SSH_ASKPASS, so don't set it.
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "PubkeyAuthentication=no",
                     "-o", "NumberOfPasswordPrompts=1"]
        } else {
            args += ["-o", "BatchMode=yes"] // key auth only; never blocks on a prompt
        }
        return args
    }

    /// Path to the SSH_ASKPASS helper, written once. The helper holds NO secret — it just
    /// echoes the `LOADOUT_SSH_PASSWORD` env var ssh passes to it.
    private static let askpassPath: String = {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("loadout-askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$LOADOUT_SSH_PASSWORD\"\n"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }()

    /// POSIX single-quote a string for safe interpolation into a remote command.
    private func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func firstLine(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
