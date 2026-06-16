import SwiftUI

/// The coding harnesses Skillz manages MCP servers for. This is a DISTINCT axis from
/// `Agent` (the skills axis), and the difference is the whole point: Pi is a skills-only
/// agent and is absent here; Cursor is an MCP-only target and is absent from `Agent`.
/// Modelling MCP through `Agent` capability flags couldn't even represent Cursor, so the
/// two resource kinds keep separate harness lists (see the task spec / DECISIONS D3).
enum McpHarness: String, CaseIterable, Identifiable, Hashable {
    case claudeCode
    case opencode
    case codex
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var badge: String {
        switch self {
        case .claudeCode: return "CC"
        case .opencode: return "OC"
        case .codex: return "CX"
        case .cursor: return "CU"
        }
    }

    /// Reuse the agent chroma where the harness IS one of the skill agents (so a server
    /// in Claude Code reads the same orange as a Claude skill); Cursor — which has no
    /// `Agent` — gets its own violet token, distinct from the four agent colors.
    var color: Color {
        switch self {
        case .claudeCode: return Color(hex: 0xD97757) // == Agent.claude
        case .opencode: return Color(hex: 0xE5484D)   // == Agent.opencode
        case .codex: return Color(hex: 0x2BA160)      // == Agent.codex
        case .cursor: return Color(hex: 0x6E56CF)     // cursor-only: violet
        }
    }

    /// Normalized transports this harness can actually express. Used to mark a server
    /// "unsupported by this harness" (a real cross-harness state, NOT "missing"): e.g. an
    /// SSE server can't live in Codex (stdio + streamable-HTTP only), so Codex shows it as
    /// locked-unsupported rather than offering to add it.
    var transportSupport: Set<McpTransport> {
        switch self {
        case .claudeCode: return [.stdio, .http, .streamableHttp, .sse, .ws]
        case .codex:      return [.stdio, .streamableHttp]            // NO sse, NO ws, NO ws
        case .opencode:   return [.stdio, .http, .streamableHttp, .sse]
        case .cursor:     return [.stdio, .http, .streamableHttp, .sse]
        }
    }

    /// The on-disk encoding of this harness's config file.
    var configFormat: McpConfigFormat {
        switch self {
        case .claudeCode, .cursor: return .json
        case .opencode: return .jsonc
        case .codex: return .toml
        }
    }
}
