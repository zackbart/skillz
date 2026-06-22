import Foundation

/// On-disk encoding of a harness's MCP config. JSONC = JSON with comments / trailing
/// commas tolerated (opencode); TOML for Codex; strict JSON elsewhere.
enum McpConfigFormat: Hashable { case json, jsonc, toml }

/// opencode's two schema shapes. v1 keeps servers directly under `mcp` and disables with
/// `enabled:false`; v2 nests them under `mcp.servers` and disables with `disabled:true`.
/// The codec detects which a file uses; the writer preserves it (and a NEW file gets v1).
enum OpencodeSchema { case v1, v2 }

/// Normalized transport kinds across dialects. Remote sub-transports are retained for
/// display, but they collapse to a "remote" family for DEFINITION-divergence comparison —
/// harnesses infer/spell remote transports differently (Claude `http` vs Codex
/// `streamable_http` for the same URL), and treating that as divergence would be a
/// false positive (the spec's central correctness concern).
enum McpTransport: String, Hashable {
    case stdio
    case http
    case streamableHttp
    case sse
    case ws

    var isRemote: Bool { self != .stdio }

    var label: String {
        switch self {
        case .stdio: return "stdio"
        case .http: return "http"
        case .streamableHttp: return "streamable-http"
        case .sse: return "sse"
        case .ws: return "ws"
        }
    }
}

/// A concrete place a harness keeps its server map: a file plus the key path within the
/// parsed document where the `{ name: definition }` map lives, plus a short UI label and
/// whether this represents the canonical/primary store for that harness+scope.
///
/// `keyPath` examples:
///   - Claude project `.mcp.json`            → `["mcpServers"]`
///   - Claude user `~/.claude.json` (user)   → `["mcpServers"]`
///   - Claude user `~/.claude.json` (local)  → `["projects", "<abs>", "mcpServers"]`
///   - opencode                              → `["mcp"]` (codec then detects v1 vs v2)
///   - Codex                                 → `["mcp_servers"]`
struct McpConfigLocation: Hashable {
    let harness: McpHarness
    let url: URL
    let format: McpConfigFormat
    let keyPath: [String]
    let label: String
    /// Primary store for the harness at this scope (project `.mcp.json` beats the nested
    /// `~/.claude.json` local map; `opencode.json` beats `opencode.jsonc`). The scanner
    /// prefers the primary when a harness has more than one origin.
    let isPrimary: Bool
}

/// Resolves WHERE each harness keeps its MCP servers for a given scope/base. Reading and
/// writing both consult this so the two stay in lockstep. Verified per-harness facts from
/// the task spec — project files at the base, user files under `$HOME`/`$XDG_CONFIG_HOME`.
enum McpConfigDescriptor {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var xdgConfigHome: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return home.appendingPathComponent(".config")
    }

    /// Global / user-scope config locations for a harness.
    static func globalLocations(_ h: McpHarness) -> [McpConfigLocation] {
        switch h {
        case .claudeCode:
            return [loc(h, home.appendingPathComponent(".claude.json"), .json,
                        ["mcpServers"], "user ~/.claude.json", primary: true)]
        case .opencode:
            return [loc(h, xdgConfigHome.appendingPathComponent("opencode/opencode.json"), .jsonc,
                        ["mcp"], "user opencode.json", primary: true)]
        case .codex:
            return [loc(h, home.appendingPathComponent(".codex/config.toml"), .toml,
                        ["mcp_servers"], "user config.toml", primary: true)]
        case .cursor:
            return [loc(h, home.appendingPathComponent(".cursor/mcp.json"), .json,
                        ["mcpServers"], "user ~/.cursor/mcp.json", primary: true)]
        }
    }

    /// Project-scope config locations for a harness within a given base directory. May
    /// return several origins for one harness (Claude's project `.mcp.json` PLUS the
    /// local-scope map nested in `~/.claude.json`; opencode's `.json` AND `.jsonc`).
    static func projectLocations(_ h: McpHarness, base: URL) -> [McpConfigLocation] {
        let basePath = base.standardizedFileURL.path
        switch h {
        case .claudeCode:
            return [
                loc(h, base.appendingPathComponent(".mcp.json"), .json,
                    ["mcpServers"], "project .mcp.json", primary: true),
                loc(h, home.appendingPathComponent(".claude.json"), .json,
                    ["projects", basePath, "mcpServers"], "user ~/.claude.json (local)", primary: false),
            ]
        case .opencode:
            return [
                loc(h, base.appendingPathComponent("opencode.json"), .jsonc,
                    ["mcp"], "project opencode.json", primary: true),
                loc(h, base.appendingPathComponent("opencode.jsonc"), .jsonc,
                    ["mcp"], "project opencode.jsonc", primary: false),
            ]
        case .codex:
            return [loc(h, base.appendingPathComponent(".codex/config.toml"), .toml,
                        ["mcp_servers"], "project .codex/config.toml", primary: true)]
        case .cursor:
            return [loc(h, base.appendingPathComponent(".cursor/mcp.json"), .json,
                        ["mcpServers"], "project .cursor/mcp.json", primary: true)]
        }
    }

    private static func loc(_ h: McpHarness, _ url: URL, _ fmt: McpConfigFormat,
                            _ keyPath: [String], _ label: String, primary: Bool) -> McpConfigLocation {
        McpConfigLocation(harness: h, url: url.standardizedFileURL, format: fmt,
                          keyPath: keyPath, label: label, isPrimary: primary)
    }
}
