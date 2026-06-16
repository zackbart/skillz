import SwiftUI

/// The kinds of resource Skillz can manage: agent skills (directories) and MCP
/// servers (entries inside shared config files). See DECISIONS D3.
enum ResourceKind: String, Hashable, CaseIterable {
    case skill
    case mcp

    var displayName: String { self == .skill ? "Skills" : "MCP" }
}

/// Scope a resource was discovered in.
enum ResourceScope: Hashable {
    case global
    case project(root: String)

    var isGlobal: Bool { if case .global = self { return true }; return false }
    var projectRoot: String? { if case .project(let r) = self { return r }; return nil }
}

/// Where a resource sits relative to git — the "is this committed / shared?" signal.
/// Reflects the resource's CANONICAL files (see Skill.gitStatus); symlink-wrapper
/// divergence is tracked separately by `Skill.linksDiverge`.
enum GitStatus: String, Hashable {
    case tracked
    case untracked
    case ignored
    case notInRepo

    var label: String {
        switch self {
        case .tracked: return "Tracked"
        case .untracked: return "Untracked"
        case .ignored: return "Ignored"
        case .notInRepo: return "Not in a repo"
        }
    }

    var systemImage: String {
        switch self {
        case .tracked: return "checkmark.seal.fill"
        case .untracked: return "questionmark.circle"
        case .ignored: return "eye.slash"
        case .notInRepo: return "minus.circle"
        }
    }

    /// One-line explanation for hover tooltips.
    var helpText: String {
        switch self {
        case .tracked: return "Committed to git — versioned and shared with the repo."
        case .untracked: return "Inside a git repo but not committed yet."
        case .ignored: return "Inside a git repo but excluded by .gitignore."
        case .notInRepo: return "Not inside any git repository (e.g. the global ~/.agents store)."
        }
    }

    var color: Color {
        switch self {
        case .tracked: return Color(hex: 0x2BA160)
        case .untracked: return Theme.drift
        case .ignored, .notInRepo: return Color(hex: 0x9AA0A6)
        }
    }
}

/// The minimal shape every managed resource shares — `Skill` and `McpServer`.
/// Deliberately just identity: anything axis-specific stays on the concrete type.
/// Skills wire into the `Agent` axis (`wiredAgents`/`declaredAgents`, filesystem
/// concepts); MCP servers live in the distinct `McpHarness` axis (present/enabled
/// per harness). Forcing either set of words onto the other would lie about the
/// model, so the protocol carries neither.
protocol AgentResource: Identifiable, Hashable {
    var id: String { get }
    var name: String { get }
    var summary: String? { get }
    var scope: ResourceScope { get }
    var kind: ResourceKind { get }
}
