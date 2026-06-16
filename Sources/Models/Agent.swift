import SwiftUI

/// The coding agents SkillsSeer understands, plus the skills.sh canonical store.
/// Paths are verified ground truth (see RESEARCH.md). `agents` is the
/// `~/.agents/skills` canonical store that skills.sh symlinks every agent back into.
enum Agent: String, CaseIterable, Identifiable, Hashable, Codable {
    case claude
    case opencode
    case codex
    case pi
    case agents // the ~/.agents/skills canonical store

    var id: String { rawValue }

    /// The real agents shown as badges/columns (the canonical store is not an agent runtime).
    static let displayAgents: [Agent] = [.claude, .opencode, .codex, .pi]

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        case .pi: return "Pi"
        case .agents: return "Canonical"
        }
    }

    var badge: String {
        switch self {
        case .claude: return "CC"
        case .opencode: return "OC"
        case .codex: return "CX"
        case .pi: return "PI"
        case .agents: return "·"
        }
    }

    /// Agent colors — the only chroma in the UI (hex tokens from the design language).
    var color: Color {
        switch self {
        case .claude: return Color(hex: 0xD97757)
        case .opencode: return Color(hex: 0xE5484D)
        case .codex: return Color(hex: 0x2BA160)
        case .pi: return Color(hex: 0x0BA5C7)
        case .agents: return Color(hex: 0x9AA0A6)
        }
    }

    /// Whether the agent reads the `.agents/skills` canonical store directly (no own
    /// symlink needed). Mirrors the `skills` CLI's `isUniversalAgent` rule — an agent is
    /// "universal" when its `skillsDir === ".agents/skills"`, in which case the CLI routes
    /// it straight to the canonical dir at BOTH global and project scope:
    ///   - OpenCode, Codex → universal (skillsDir = ".agents/skills") → read canonical.
    ///   - Pi → not universal in the CLI, but its own docs list `.agents/skills` as a
    ///     discovery dir, so it reaches canonical skills too.
    ///   - Claude Code → NOT universal (skillsDir = ".claude/skills") → needs a symlink.
    /// Only Claude Code shows drift when a skill is in the canonical store but unwired.
    var readsCanonicalNatively: Bool {
        switch self {
        case .opencode, .codex, .pi, .agents: return true
        case .claude: return false
        }
    }

    /// Map a skills-CLI `agents[]` display string to an Agent (declared intent).
    static func from(cliDisplayName name: String) -> Agent? {
        switch name {
        case "Claude Code": return .claude
        case "OpenCode": return .opencode
        case "Codex": return .codex
        case "Pi": return .pi
        default: return nil // Zed, OpenClaw, etc. are out of scope
        }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var xdgConfigHome: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return home.appendingPathComponent(".config")
    }

    /// Global/user-level skill discovery directories.
    var globalSkillDirs: [URL] {
        let home = Agent.home
        switch self {
        case .claude: return [home.appendingPathComponent(".claude/skills")]
        case .opencode: return [Agent.xdgConfigHome.appendingPathComponent("opencode/skills")]
        case .codex: return [home.appendingPathComponent(".codex/skills")]
        case .pi: return [home.appendingPathComponent(".pi/agent/skills")]
        case .agents: return [home.appendingPathComponent(".agents/skills")]
        }
    }

    /// Project-relative skill directories (scanned by walking cwd → git root).
    var projectSkillDirs: [String] {
        switch self {
        case .claude: return [".claude/skills"]
        case .opencode: return [".opencode/skills"]
        case .codex: return [".codex/skills"]
        case .pi: return [".pi/skills"]
        case .agents: return [".agents/skills"]
        }
    }
}
