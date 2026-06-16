import Foundation

/// Provenance from a lock file. Best-effort: any field may be absent.
/// Global lock (`~/.agents/.skill-lock.json`, v3) uses `skillFolderHash`;
/// project lock (`<root>/skills-lock.json`, v1) uses `computedHash` — both map here.
struct SkillProvenance: Hashable {
    var source: String
    var sourceURL: String?
    var skillPath: String?
    var folderHash: String?
    var installedAt: String?
    var updatedAt: String?
    var pluginName: String?
}

/// A skill, identified by its canonical (symlink-resolved) directory **within a scope**.
/// The composite `id` keeps the same canonical skill from colliding between global and
/// project scopes (they are never shown together, but the IDs must still be distinct).
struct Skill: AgentResource {
    let canonicalPath: String
    var scope: ResourceScope
    var id: String { "\(scope.projectRoot ?? "global")::\(canonicalPath)" }

    let name: String
    let directoryURL: URL
    let skillMdURL: URL

    var summary: String?
    var bodyMarkdown: String
    var frontmatterKeys: [String]
    var rawFrontmatter: String

    /// Top-level files/dirs packaged alongside SKILL.md in the canonical skill dir
    /// (reference docs, scripts, templates, assets). Excludes SKILL.md itself. Sorted
    /// dirs-first then by name; `isDirectory` lets the UI pick a folder vs file glyph.
    var bundledFiles: [BundledFile] = []

    var kind: ResourceKind { .skill }

    /// Agents whose own dir references this skill on disk (real dir OR symlink).
    var wiredAgents: Set<Agent>
    /// Subset of `wiredAgents` whose reference is an actual SYMLINK (resolving elsewhere,
    /// usually the canonical store). The complement live as real directories in the
    /// agent's own dir — so the UI can say "symlinked" vs "local" honestly.
    var symlinkedAgents: Set<Agent> = []
    /// Agents the skills CLI declares as targets (intent).
    var declaredAgents: Set<Agent> = []

    var provenance: SkillProvenance?

    /// Project-relative subpackage paths this skill is referenced from (project scope only;
    /// empty for global). "" means the chosen project root; "↑ …" means an ancestor dir.
    /// A monorepo skill referenced from one place has a single entry.
    var projectLocations: [String] = []

    /// A short label for where this lives in the project, or nil in global scope.
    var locationBadge: String? {
        guard !projectLocations.isEmpty else { return nil }
        let labels = projectLocations.map { $0.isEmpty ? "· root" : $0 }
        return labels.count == 1 ? labels[0] : "\(labels[0]) +\(labels.count - 1)"
    }

    // Derived signals (filled in by the scanner)
    var gitStatus: GitStatus = .notInRepo
    /// True when the agent-dir symlinks differ in tracked-ness from the canonical files.
    var linksDiverge: Bool = false
    var isCLIManaged: Bool = false
    /// True when ≥2 skills in the same scope share this name across distinct canonical paths.
    var diverged: Bool = false

    /// True when the skill exists in the canonical `.agents/skills` store.
    var canonicalPresent: Bool { wiredAgents.contains(.agents) }

    /// Agents that can actually USE this skill: either wired into their own dir, or
    /// reading the canonical store natively when it's present. This is the key fix —
    /// a canonical skill is available to Codex/OpenCode/Pi even with no per-agent symlink.
    var availableAgents: Set<Agent> {
        var result = wiredAgents
        if canonicalPresent {
            for agent in Agent.allCases where agent.readsCanonicalNatively {
                result.insert(agent)
            }
        }
        return result
    }

    /// How a given agent reaches this skill.
    func access(_ agent: Agent) -> AgentAccess {
        if wiredAgents.contains(agent) { return .wired }
        if agent.readsCanonicalNatively && canonicalPresent { return .viaCanonical }
        return .none
    }

    /// True when `agent`'s reference is a real directory living in its own skills dir,
    /// not a symlink to the canonical store (e.g. a hand-made project skill in `.claude/skills`).
    func isLocalDir(_ agent: Agent) -> Bool {
        wiredAgents.contains(agent) && !symlinkedAgents.contains(agent)
    }

    /// Agents the CLI declares but that genuinely can't reach the skill (drift).
    var driftMissing: Set<Agent> { declaredAgents.subtracting(availableAgents) }
}

/// A file or directory packaged inside a skill, surfaced in the detail view.
struct BundledFile: Hashable, Identifiable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// How an agent gets access to a skill.
enum AgentAccess: Hashable {
    case wired         // a symlink/entry in the agent's own dir
    case viaCanonical  // reached through the shared .agents/skills store
    case none

    var label: String {
        switch self {
        case .wired: return "symlinked"
        case .viaCanonical: return "via .agents"
        case .none: return "not available"
        }
    }
}
