import SwiftUI
import HerdrKit

/// Presentation-only style tokens for the Agents axis, mapping live domain values to
/// the app's existing chroma discipline (grayscale chrome; chroma only for identity
/// dots + the amber drift/status token). Mirrors the v2 mockup.
enum AgentStyle {
    /// Functional status color — distinct from agent brand identity.
    /// working → green, blocked → amber (drift), idle/done/unknown → gray.
    static func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return Color(hex: 0x2BA160)
        case .blocked: return Theme.drift
        case .idle, .done, .unknown: return Color(hex: 0x9AA0A6)
        }
    }

    /// A short status label for capsules / pills.
    static func statusLabel(_ status: AgentStatus) -> String {
        switch status {
        case .working: return "working"
        case .blocked: return "blocked"
        case .idle: return "idle"
        case .done: return "done"
        case .unknown: return "unknown"
        }
    }

    /// The brand identity color for an agent name (the IDENTITY dot/avatar).
    /// Falls back to gray for non-agents / unrecognized names.
    static func identityColor(_ agentName: String?) -> Color {
        switch agentName?.lowercased() {
        case "claude": return Agent.claude.color
        case "codex": return Agent.codex.color
        case "opencode": return Agent.opencode.color
        case "pi": return Agent.pi.color
        case "cursor": return Color(hex: 0x6E56CF)
        default: return Color(hex: 0x9AA0A6)
        }
    }

    /// The colored uppercase type tag for a tool-call card, by tool name.
    /// Bash → codex green, Edit → cursor violet, Read → pi cyan, everything else → gray.
    static func toolTagColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "bash": return Agent.codex.color
        case "edit", "multiedit": return Color(hex: 0x6E56CF)
        case "read": return Agent.pi.color
        case "write": return Agent.claude.color
        default: return Color(hex: 0x9AA0A6)
        }
    }

    /// SF Symbol for a work-log row, by tool name (T3-style one-liner icon).
    static func toolSymbol(_ name: String) -> String {
        switch name.lowercased() {
        case "read": return "eye"
        case "edit", "multiedit", "write": return "square.and.pencil"
        case "bash": return "terminal"
        case "skill": return "puzzlepiece.extension"
        case "agent", "task": return "sparkles"
        case "webfetch", "websearch", "web_search": return "globe"
        case "todowrite": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    /// Collapse a full `cwd` path to a tasteful `~/Dev/…/leaf` form (mono, truncatable).
    static func shortCwd(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = path
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/").map(String.init)
        guard parts.count > 3 else { return p }
        return "\(parts[0])/\(parts[1])/…/\(parts.last!)"
    }
}
