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
    static func locate(_ io: HostIO) -> URL? {
        let home = io.home.path
        let candidates = [
            "/opt/homebrew/bin/skills",
            "/usr/local/bin/skills",
            "\(home)/.local/bin/skills",
        ]
        for path in candidates where io.exists(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func isAvailable(_ io: HostIO) -> Bool { locate(io) != nil }

    /// `skills list -g --json` — global skills with their declared agent targets.
    static func listGlobalJSON(io: HostIO) -> [CLISkill] {
        run(arguments: ["list", "-g", "--json"], io: io)
    }

    /// `skills list --json` run in `directory` — project-scoped skills.
    static func listProjectJSON(in directory: URL, io: HostIO) -> [CLISkill] {
        run(arguments: ["list", "--json"], cwd: directory, io: io)
    }

    private static func run(arguments: [String], cwd: URL? = nil, io: HostIO) -> [CLISkill] {
        guard let bin = locate(io) else { return [] }
        let r = io.run([bin.path] + arguments, cwd: cwd?.path, stdin: nil)
        guard r.exit != -1 else { return [] }
        return (try? JSONDecoder().decode([CLISkill].self, from: r.stdout)) ?? []
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
    static func runCapturing(arguments: [String], cwd: URL? = nil, io: HostIO) -> CLIResult {
        guard let bin = locate(io) else {
            return CLIResult(exitCode: 127, stdout: "", stderr: "skills CLI not found on PATH")
        }
        let r = io.run([bin.path] + arguments, cwd: cwd?.path, stdin: nil)
        if r.exit == -1 {
            return CLIResult(exitCode: 126, stdout: "", stderr: "failed to launch skills CLI")
        }
        return CLIResult(exitCode: r.exit,
                         stdout: String(decoding: r.stdout, as: UTF8.self),
                         stderr: String(decoding: r.stderr, as: UTF8.self))
    }

    /// `-a` takes the agent slugs as separate following tokens (one flag, many values) —
    /// NOT a comma-joined string, which the CLI would treat as a single invalid slug.
    /// Placed last by callers so the variadic flag can't swallow a trailing option.
    private static func agentArgs(_ agents: [Agent]) -> [String] {
        let slugs = agents.compactMap { slug(for: $0) }
        return slugs.isEmpty ? [] : ["-a"] + slugs
    }

    /// Scope→(extra args, cwd). Project ops are cwd-sensitive: pass `-p` AND set cwd.
    private static func scopeArgs(_ scope: ResourceScope) -> (args: [String], cwd: URL?) {
        if scope.isGlobal { return (["-g"], nil) }
        let root = scope.projectRoot.map { URL(fileURLWithPath: $0) }
        return (["-p"], root)
    }

    /// INSTALL a whole package or a specific skill into specific agents.
    /// `skills add <ref> [-s <skill>] (-g|-p) -y [--copy] [-a <slug>...]`
    static func add(ref: String, skill: String? = nil, agents: [Agent] = [], scope: ResourceScope, copy: Bool = false, io: HostIO) -> CLIResult {
        let s = scopeArgs(scope)
        var a = ["add", ref] + s.args + ["-y"]
        if let skill { a += ["-s", skill] }
        if copy { a += ["--copy"] }
        a += agentArgs(agents) // variadic flag last
        return runCapturing(arguments: a, cwd: s.cwd, io: io)
    }

    /// REMOVE a skill fully, or unwire from specific agents only (`-a`).
    /// `skills remove <name> (-g|-p) -y [-a <slug>...]`
    static func remove(name: String, agents: [Agent] = [], scope: ResourceScope, io: HostIO) -> CLIResult {
        let s = scopeArgs(scope)
        var a = ["remove", name] + s.args + ["-y"]
        a += agentArgs(agents) // variadic flag last
        return runCapturing(arguments: a, cwd: s.cwd, io: io)
    }

    /// UPDATE installed skill(s) to latest from source.
    /// `skills update [<name>] (-g|-p) -y`
    static func update(name: String?, scope: ResourceScope, io: HostIO) -> CLIResult {
        let s = scopeArgs(scope)
        var a = ["update"]
        if let name { a.append(name) }
        a += s.args + ["-y"]
        return runCapturing(arguments: a, cwd: s.cwd, io: io)
    }
}
