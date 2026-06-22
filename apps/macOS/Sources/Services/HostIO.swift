import Foundation

/// One directory entry as the scan path needs it: name plus the lstat-derived flags
/// (the entry's OWN type, not its target's) and the symlink target when it is one.
/// Sendable so a `Host`-derived scan can cross the `Task.detached` boundary.
struct DirEntry: Sendable {
    let name: String
    let isDir: Bool
    let isSymlink: Bool
    let linkTarget: String?
}

enum HostIOError: Error {
    case readOnly
    case io(String)
}

/// The per-host IO seam (filesystem + process). `LocalHostIO` wraps today's Foundation
/// calls verbatim-equivalently; a future `RemoteHostIO` runs the same operations over SSH.
/// Sendable so a host-scoped scan can run off the main actor.
protocol HostIO: Sendable {
    var home: URL { get }
    var xdgConfigHome: URL { get }
    func exists(_ path: String) -> Bool
    func readFile(_ path: String) throws -> Data
    func listDir(_ path: String) throws -> [DirEntry]
    func realpath(_ path: String) -> String
    func run(_ argv: [String], cwd: String?, stdin: Data?) -> (exit: Int32, stdout: Data, stderr: Data)
}

/// Which machine a resource was discovered on. Carried separately from `ResourceScope`
/// so resource identities stay unique per host; local renders `idTag == nil`, keeping
/// local ids byte-identical to before the seam existed.
enum Host: Sendable, Hashable {
    case local
    case remote(user: String, host: String, alias: String?)

    /// What `ssh` connects to: an `~/.ssh/config` alias if given, else `user@host`.
    var target: String {
        switch self {
        case .local: return ""
        case .remote(let u, let h, let a): return a ?? "\(u)@\(h)"
        }
    }

    /// Identity prefix for resource ids; `nil` for local so local ids are unchanged.
    var idTag: String? {
        switch self {
        case .local: return nil
        case .remote: return target
        }
    }

    /// Human label for the UI (the ssh target).
    var displayName: String { self == .local ? "Local" : target }

    func makeIO() -> HostIO {
        switch self {
        case .local: return LocalHostIO()
        case .remote: return RemoteHostIO(target: target)
        }
    }

    /// Parse user input into a host. `user@host` → a literal target; anything else is
    /// treated as an `~/.ssh/config` alias. Returns nil for empty input.
    static func parse(_ input: String) -> Host? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let at = s.firstIndex(of: "@"), at != s.startIndex, s.index(after: at) != s.endIndex {
            return .remote(user: String(s[..<at]), host: String(s[s.index(after: at)...]), alias: nil)
        }
        return .remote(user: "", host: "", alias: s)
    }
}

/// Local implementation — each method wraps the exact Foundation call it replaced, so
/// Slice 0 is a behavior-preserving refactor.
struct LocalHostIO: HostIO {
    var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var xdgConfigHome: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return home.appendingPathComponent(".config")
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func readFile(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func listDir(_ path: String) throws -> [DirEntry] {
        let fm = FileManager.default
        // Skip hidden files (names starting "."), matching the `.skipsHiddenFiles` option
        // used at every former call site.
        let names = try fm.contentsOfDirectory(atPath: path).filter { !$0.hasPrefix(".") }
        return names.map { name in
            let full = (path as NSString).appendingPathComponent(name)
            // lstat via attributesOfItem (doesn't follow links) for the entry's own type.
            let attrs = try? fm.attributesOfItem(atPath: full)
            let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            // isDir via resourceValues (FOLLOWS links) — matches the descendantRoots /
            // bundledFiles use of `.isDirectoryKey`.
            let isDir = (try? URL(fileURLWithPath: full)
                .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let linkTarget = isSymlink
                ? (try? fm.destinationOfSymbolicLink(atPath: full))
                : nil
            return DirEntry(name: name, isDir: isDir, isSymlink: isSymlink, linkTarget: linkTarget)
        }
    }

    func realpath(_ path: String) -> String {
        // resolvingSymlinksInPath also standardizes `..`/`~`, which `readlink -f` alone
        // wouldn't — keeping local canonicalization byte-identical to the prior code.
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func run(_ argv: [String], cwd: String?, stdin: Data?) -> (exit: Int32, stdout: Data, stderr: Data) {
        spawnProcess(argv, cwd: cwd, stdin: stdin, env: nil)
    }
}

/// Mutable reference box so the two concurrent pipe-reader closures each write a distinct
/// slot; `group.wait()` establishes the happens-before before we read them.
private final class DataBox: @unchecked Sendable { var data = Data() }

/// Spawn a process, draining stdout+stderr concurrently and feeding stdin off-thread (so a
/// large input can't deadlock against our reads). `env`, when non-nil, is merged over the
/// inherited environment — RemoteHostIO uses it to inject SSH_ASKPASS for password auth.
/// Shared by LocalHostIO.run and RemoteHostIO so both get the same deadlock-safe behavior.
func spawnProcess(_ argv: [String], cwd: String?, stdin: Data?,
                  env: [String: String]?) -> (exit: Int32, stdout: Data, stderr: Data) {
    guard let first = argv.first else { return (-1, Data(), Data()) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: first)
    p.arguments = Array(argv.dropFirst())
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let env {
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in env { merged[k] = v }
        p.environment = merged
    }

    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let inPipe: Pipe?
    if stdin != nil { inPipe = Pipe(); p.standardInput = inPipe } else { inPipe = nil }

    do { try p.run() } catch { return (-1, Data(), Data()) }

    // `write(contentsOf:)` throws on a broken pipe (the child closing stdin early); the
    // older `write(_:)` traps and would crash the app.
    if let inPipe, let stdin {
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }
    }

    let outBox = DataBox(), errBox = DataBox()
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
        outBox.data = out.fileHandleForReading.readDataToEndOfFile()
    }
    DispatchQueue.global().async(group: group) {
        errBox.data = err.fileHandleForReading.readDataToEndOfFile()
    }
    group.wait()
    p.waitUntilExit()
    return (p.terminationStatus, outBox.data, errBox.data)
}
