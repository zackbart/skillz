import SwiftUI

/// The kinds of resource SkillsSeer can manage. MCP is reserved (D3) — discovery
/// is not implemented yet, but the model + UI leave the door open.
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

    var color: Color {
        switch self {
        case .tracked: return Color(hex: 0x2BA160)
        case .untracked: return Theme.drift
        case .ignored, .notInRepo: return Color(hex: 0x9AA0A6)
        }
    }
}

/// The minimal shape every managed resource shares — `Skill` now, a future
/// `McpServer` later. Deliberately small: filesystem-only concepts (canonical
/// path, git status, provenance, CLI-managed) stay on `Skill`, since MCP servers
/// are config-file entries, not directories (DECISIONS.md D3).
protocol AgentResource: Identifiable, Hashable {
    var id: String { get }
    var name: String { get }
    var summary: String? { get }
    var scope: ResourceScope { get }
    var kind: ResourceKind { get }
    var wiredAgents: Set<Agent> { get }
    var declaredAgents: Set<Agent> { get }
}
