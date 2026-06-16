import Foundation

/// A config value parsed into a typed interpolation expression, so the SAME logical value
/// expressed in different dialects compares equal. `${VAR}` (Claude/Cursor) and `{env:VAR}`
/// (opencode) both normalize to `.envVar("VAR")`; Codex's literal strings stay `.literal`.
/// This is what stops cosmetic dialect differences from reading as divergence.
enum McpValueExpr: Hashable {
    case literal(String)
    case envVar(String)
    case envVarDefault(String, String)
    case fileRef(String)

    /// How a harness spells interpolation inside its config values.
    enum Dialect { case dollar, opencode, literal }

    static func parse(_ raw: String, dialect: Dialect) -> McpValueExpr {
        switch dialect {
        case .literal:
            return .literal(raw)
        case .dollar:
            // ${VAR} / ${VAR:-default}; anything else is a literal (incl. partial interps).
            guard raw.hasPrefix("${"), raw.hasSuffix("}"), raw.count >= 4 else { return .literal(raw) }
            let inner = String(raw.dropFirst(2).dropLast())
            if let r = inner.range(of: ":-") {
                let name = String(inner[..<r.lowerBound])
                let def = String(inner[r.upperBound...])
                return isVarName(name) ? .envVarDefault(name, def) : .literal(raw)
            }
            return isVarName(inner) ? .envVar(inner) : .literal(raw)
        case .opencode:
            // {env:VAR} / {file:PATH}; anything else literal.
            guard raw.hasPrefix("{"), raw.hasSuffix("}"), raw.count >= 3 else { return .literal(raw) }
            let inner = String(raw.dropFirst().dropLast())
            if inner.hasPrefix("env:") {
                let name = String(inner.dropFirst(4))
                return isVarName(name) ? .envVar(name) : .literal(raw)
            }
            if inner.hasPrefix("file:") {
                return .fileRef(String(inner.dropFirst(5)))
            }
            return .literal(raw)
        }
    }

    private static func isVarName(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// A harness-agnostic MCP server definition. Built by normalizing each harness's raw entry
/// so equivalent servers compare equal regardless of dialect:
///   - opencode `command: ["npx","-y","pkg"]` == Claude `command: "npx", args: ["-y","pkg"]`.
///   - `env` (Claude/Codex/Cursor) vs `environment` (opencode) compare as the same map.
///   - interpolation is parsed into `McpValueExpr`, not raw strings.
/// Agent-local auth/header fields are deliberately NOT carried here — they are never part of
/// portable divergence (tracked on `AgentMcpEntry.agentLocalFields` instead).
struct PortableMcpDefinition: Hashable {
    enum Kind: Hashable { case stdio, remote }

    var kind: Kind
    // stdio
    var command: String?
    var args: [String]
    var env: [String: McpValueExpr]
    var cwd: String?
    // remote
    var url: String?
    /// The remote sub-transport, for display only — excluded from `signature`.
    var remoteTransport: McpTransport?

    /// The normalized transport (stdio, or the remote sub-transport, defaulting to http).
    var transport: McpTransport {
        kind == .stdio ? .stdio : (remoteTransport ?? .http)
    }

    /// The fields compared for cross-harness DEFINITION divergence. Excludes the remote
    /// sub-transport (harnesses infer/spell it differently) and all agent-local fields.
    struct Signature: Hashable {
        let kind: Kind
        let command: String?
        let args: [String]
        let env: [String: McpValueExpr]
        let cwd: String?
        let url: String?
    }

    var signature: Signature {
        Signature(kind: kind, command: command, args: args, env: env, cwd: cwd, url: url)
    }

    /// One-line human summary of the connection ("stdio · npx -y @linear/mcp", "http · https://…").
    var summary: String {
        switch kind {
        case .stdio:
            let cmd = ([command].compactMap { $0 } + args).joined(separator: " ")
            return "stdio · \(cmd)"
        case .remote:
            return "\(transport.label) · \(url ?? "—")"
        }
    }
}

/// One harness's view of a single server: its parsed portable definition (nil when the raw
/// entry couldn't be normalized), whether it's enabled, why it might be unsupported, and the
/// NAMES of any agent-local / secret-bearing fields present (so the writer knows to preserve
/// them and the UI can say "carries auth" without ever surfacing the secret).
struct AgentMcpEntry: Hashable {
    var portable: PortableMcpDefinition?
    var enabled: Bool
    /// Non-portable, harness-local field names present on the raw entry (oauth, headers,
    /// headersHelper, bearer_token_env_var, http_headers, env_http_headers, Cursor `auth`,
    /// `envFile`, …). Key names only — never values.
    var agentLocalFields: [String]
    /// Set when the raw entry was present but couldn't be parsed into a portable definition.
    var unparsableReason: String?
}
