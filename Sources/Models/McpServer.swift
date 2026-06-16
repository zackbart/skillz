import SwiftUI

/// How a server stands in one harness — the FOUR cross-harness states (not two). Rendered
/// distinctly: `unsupported` is never shown as "missing" or "diverged".
enum McpServerState: Hashable {
    case enabled            // present and on
    case disabled           // present but turned off (opencode `enabled:false`, Codex `enabled=false`)
    case missing            // absent, but this harness COULD host it
    case unsupported        // absent, and this harness can't express its transport

    var label: String {
        switch self {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .missing: return "missing"
        case .unsupported: return "unsupported"
        }
    }

    var systemImage: String {
        switch self {
        case .enabled: return "checkmark.circle.fill"
        case .disabled: return "pause.circle"
        case .missing: return "circle.dashed"
        case .unsupported: return "nosign"
        }
    }
}

/// An MCP server collapsed across every harness that knows about it, within one scope.
///
/// Identity is `scope + logicalLocation + serverName`, so the same-named server in two
/// monorepo subpackages (or an ancestor dir) stays distinct, while the same server defined
/// in several harnesses' configs at one location collapses into a single row.
struct McpServer: AgentResource {
    let name: String
    var scope: ResourceScope
    /// Project-relative subpackage the config(s) live in. "" = the chosen project root;
    /// "↑ <dir>" = an ancestor above it; empty for global scope. Part of identity.
    var logicalLocation: String

    var id: String { "\(scope.projectRoot ?? "global")::\(logicalLocation)::\(name)" }
    var kind: ResourceKind { .mcp }

    /// Per-harness parsed entry, only for harnesses where the server is actually present.
    var entries: [McpHarness: AgentMcpEntry]
    /// Where each present harness's definition was read from (≥1; >1 when origins coexist,
    /// e.g. Claude project `.mcp.json` and the `~/.claude.json` local map).
    var origins: [McpHarness: [McpConfigLocation]]
    /// Git status of each present harness's primary config file.
    var gitStatusByHarness: [McpHarness: GitStatus]
    /// Harnesses where two origins for the SAME harness disagree on the definition
    /// (e.g. Claude `.mcp.json` vs `~/.claude.json` local) — a conflict to surface, not fix.
    /// (Whole-file malformed configs can't be attributed to a single server, so those are
    /// reported separately as scanner-level `McpConfigIssue`s.)
    var conflictedHarnesses: Set<McpHarness>

    // MARK: AgentResource

    var summary: String? {
        representativePortable?.summary ?? "—"
    }

    // MARK: - Derived

    var presentIn: Set<McpHarness> { Set(entries.keys) }
    var enabledIn: Set<McpHarness> { Set(entries.filter { $0.value.enabled }.keys) }

    /// A representative portable definition (the first present harness that parsed one),
    /// used for the summary and for the transport an absent harness is judged against.
    var representativePortable: PortableMcpDefinition? {
        for h in McpHarness.allCases {
            if let p = entries[h]?.portable { return p }
        }
        return nil
    }

    var transport: McpTransport? { representativePortable?.transport }

    /// True when the parsed portable definitions disagree across the harnesses that have
    /// one — a *definition* divergence, kept separate from mere availability differences.
    var definitionDiverges: Bool {
        let sigs = entries.values.compactMap { $0.portable?.signature }
        return Set(sigs).count > 1
    }

    /// Harnesses where the server is present but with auth/secret-bearing fields — the
    /// writer must preserve these on edit, never strip them.
    var carriesAuth: Bool { entries.values.contains { !$0.agentLocalFields.isEmpty } }

    /// The cross-harness state for `h`: present → enabled/disabled; otherwise missing unless
    /// the server's transport is one this harness can't express → unsupported.
    func state(_ h: McpHarness) -> McpServerState {
        if let e = entries[h] { return e.enabled ? .enabled : .disabled }
        if let t = transport, !h.transportSupport.contains(t) { return .unsupported }
        return .missing
    }

    /// Harnesses that support this server's transport but don't yet have it (drift you could
    /// fix with "apply to supported harnesses"). Drives the supported-subset actions later.
    var supportedButMissing: Set<McpHarness> {
        Set(McpHarness.allCases.filter { state($0) == .missing })
    }

    /// Harnesses locked out by transport — rendered distinctly, never offered an "add".
    var unsupportedHarnesses: Set<McpHarness> {
        Set(McpHarness.allCases.filter { state($0) == .unsupported })
    }

    /// Worst-case git status across present harnesses, for the row glyph (untracked beats
    /// tracked as the "needs attention" signal, matching the skill side's intent).
    var gitStatus: GitStatus {
        let statuses = Set(gitStatusByHarness.values)
        for s in [GitStatus.untracked, .ignored, .tracked, .notInRepo] where statuses.contains(s) {
            return s
        }
        return .notInRepo
    }
}
