import Foundation

/// One entry from `skills list --json`.
struct CLISkill: Decodable {
    let name: String
    let path: String
    let scope: String
    let agents: [String]
}

/// Outcome of a mutating CLI call — exit code + captured streams, so failures
/// surface to the UI instead of being swallowed (the read-only `run` returns []).
struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { exitCode == 0 }
    /// Best human-readable message: prefer stderr, fall back to stdout.
    var message: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : e
    }
}

/// Bridge to the skills.sh `skills` CLI.
///
/// GUI apps don't inherit the user's shell PATH, so we locate the binary at known
/// install locations rather than relying on `npx` (which can be slow / networked /
/// a different version). All mutations should route through this service.
enum SkillsCLIService {
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/skills",
            "/usr/local/bin/skills",
            "\(home)/.local/bin/skills",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var isAvailable: Bool { locate() != nil }

    /// `skills list -g --json` — global skills with their declared agent targets.
    static func listGlobalJSON() -> [CLISkill] {
        run(arguments: ["list", "-g", "--json"])
    }

    /// `skills list --json` run in `directory` — project-scoped skills.
    static func listProjectJSON(in directory: URL) -> [CLISkill] {
        run(arguments: ["list", "--json"], cwd: directory)
    }

    private static func run(arguments: [String], cwd: URL? = nil) -> [CLISkill] {
        guard let bin = locate() else { return [] }
        let process = Process()
        process.executableURL = bin
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return (try? JSONDecoder().decode([CLISkill].self, from: data)) ?? []
    }

    // MARK: - Mutations

    /// CLI `-a`/`-s` expect SLUGS; `list --json` emits DISPLAY names. Map Agent→slug.
    /// `.agents` (the canonical store) is not a wireable agent target → nil.
    static func slug(for agent: Agent) -> String? {
        switch agent {
        case .claude: return "claude-code"
        case .opencode: return "opencode"
        case .codex: return "codex"
        case .pi: return "pi"
        case .agents: return nil
        }
    }

    /// Generic capturing runner (parallel to `run`, but keeps exit code + streams).
    /// Runs synchronously — callers must invoke it off the main thread.
    @discardableResult
    static func runCapturing(arguments: [String], cwd: URL? = nil) -> CLIResult {
        guard let bin = locate() else {
            return CLIResult(exitCode: 127, stdout: "", stderr: "skills CLI not found on PATH")
        }
        let p = Process()
        p.executableURL = bin
        p.arguments = arguments
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            return CLIResult(exitCode: 126, stdout: "", stderr: error.localizedDescription)
        }
        // Read BEFORE waitUntilExit to avoid a pipe-buffer deadlock on large output.
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CLIResult(exitCode: p.terminationStatus,
                         stdout: String(decoding: o, as: UTF8.self),
                         stderr: String(decoding: e, as: UTF8.self))
    }

    /// Scope→(extra args, cwd). Project ops are cwd-sensitive: pass `-p` AND set cwd.
    private static func scopeArgs(_ scope: ResourceScope) -> (args: [String], cwd: URL?) {
        if scope.isGlobal { return (["-g"], nil) }
        let root = scope.projectRoot.map { URL(fileURLWithPath: $0) }
        return (["-p"], root)
    }

    /// INSTALL a whole package or a specific skill into specific agents.
    /// `skills add <ref> [-s <skill>] [-a <slug,...>] (-g|-p) -y [--copy]`
    static func add(ref: String, skill: String? = nil, agents: [Agent] = [], scope: ResourceScope, copy: Bool = false) -> CLIResult {
        let s = scopeArgs(scope)
        var a = ["add", ref] + s.args + ["-y"]
        if let skill { a += ["-s", skill] }
        let slugs = agents.compactMap { slug(for: $0) }
        if !slugs.isEmpty { a += ["-a", slugs.joined(separator: ",")] }
        if copy { a += ["--copy"] }
        return runCapturing(arguments: a, cwd: s.cwd)
    }

    /// REMOVE a skill fully, or unwire from specific agents only (`-a`).
    /// `skills remove <name> [-a <slug,...>] (-g|-p) -y`
    static func remove(name: String, agents: [Agent] = [], scope: ResourceScope) -> CLIResult {
        let s = scopeArgs(scope)
        var a = ["remove", name] + s.args + ["-y"]
        let slugs = agents.compactMap { slug(for: $0) }
        if !slugs.isEmpty { a += ["-a", slugs.joined(separator: ",")] }
        return runCapturing(arguments: a, cwd: s.cwd)
    }

    /// UPDATE installed skill(s) to latest from source.
    /// `skills update [<name>] (-g|-p) -y`
    static func update(name: String?, scope: ResourceScope) -> CLIResult {
        let s = scopeArgs(scope)
        var a = ["update"]
        if let name { a.append(name) }
        a += s.args + ["-y"]
        return runCapturing(arguments: a, cwd: s.cwd)
    }
}
