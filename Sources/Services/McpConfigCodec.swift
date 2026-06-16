import Foundation

/// READ side of the MCP config layer: locate a config file, parse it in its format, find
/// the server map at the location's key path, and normalize each raw entry into a
/// per-harness `AgentMcpEntry` (portable definition + enabled + agent-local field names).
///
/// Parsing is tolerant of ABSENCE (missing file or missing key → no servers) but strict on
/// MALFORMED content: an unreadable/invalid file returns `.malformed` and is never "fixed".
/// opencode is read as a versioned codec — v1 (`mcp` map, `enabled`) and v2
/// (`mcp.servers`, `disabled`) both decode here.
enum McpConfigCodec {
    enum ReadResult {
        case absent                         // file or key path not present → no servers
        case malformed(String)              // file present but unparsable / wrong shape
        case ok([String: AgentMcpEntry])    // serverName → normalized entry
    }

    static func read(_ loc: McpConfigLocation) -> ReadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: loc.url.path) else { return .absent }
        guard let data = try? Data(contentsOf: loc.url) else {
            return .malformed("could not read \(loc.url.lastPathComponent)")
        }

        let top: [String: Any]
        switch loc.format {
        case .json, .jsonc:
            // Comment/trailing-comma tolerant for both: the write path edits such files
            // losslessly, so the read path must not reject them as malformed.
            let stripped = stripJsonc(String(decoding: data, as: UTF8.self))
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(stripped.utf8)) as? [String: Any] else {
                return .malformed("invalid JSON in \(loc.url.lastPathComponent)")
            }
            top = obj
        case .toml:
            do {
                top = try TomlMiniReader.parse(String(decoding: data, as: UTF8.self))
            } catch {
                let reason = (error as? TomlMiniReader.ParseError)?.message ?? "\(error)"
                return .malformed("invalid TOML in \(loc.url.lastPathComponent): \(reason)")
            }
        }

        // Navigate the key path; a missing intermediate just means "no servers here".
        guard let container = navigate(top, loc.keyPath) else { return .absent }

        // Resolve the actual server map (opencode may nest it under v2 `servers`).
        let serverMap: [String: Any]
        let schema: OpencodeSchema
        if loc.harness == .opencode, let nested = container["servers"] as? [String: Any] {
            serverMap = nested
            schema = .v2
        } else {
            serverMap = container
            schema = .v1
        }

        var out: [String: AgentMcpEntry] = [:]
        for (name, raw) in serverMap {
            guard let def = raw as? [String: Any] else {
                out[name] = AgentMcpEntry(portable: nil, enabled: true, agentLocalFields: [],
                                          unparsableReason: "entry is not a table/object")
                continue
            }
            out[name] = normalize(def, harness: loc.harness, schema: schema)
        }
        return .ok(out)
    }

    // MARK: - Navigation

    private static func navigate(_ top: [String: Any], _ keyPath: [String]) -> [String: Any]? {
        var cur: [String: Any] = top
        for key in keyPath {
            guard let next = cur[key] as? [String: Any] else { return nil }
            cur = next
        }
        return cur
    }

    // MARK: - Per-harness normalization

    private static func normalize(_ def: [String: Any], harness: McpHarness,
                                  schema: OpencodeSchema) -> AgentMcpEntry {
        switch harness {
        case .claudeCode, .cursor:
            return normalizeJsonStyle(def, harness: harness)
        case .codex:
            return normalizeCodex(def)
        case .opencode:
            return normalizeOpencode(def, schema: schema)
        }
    }

    /// Claude Code & Cursor: `command`/`args`/`env` (string + array), remote via `type`/`url`.
    /// Interpolation dialect is `${VAR}`. No per-entry enable flag → always enabled when present.
    private static func normalizeJsonStyle(_ def: [String: Any], harness: McpHarness) -> AgentMcpEntry {
        let localKeys = harness == .cursor
            ? ["auth", "envFile", "headers"]
            : ["oauth", "headers", "headersHelper"]
        let agentLocal = localKeys.filter { def[$0] != nil }

        let typeStr = (def["type"] as? String)?.lowercased()
        let url = def["url"] as? String
        if url != nil || isRemoteType(typeStr) {
            let portable = PortableMcpDefinition(
                kind: .remote, command: nil, args: [], env: [:], cwd: nil,
                url: url, remoteTransport: remoteTransport(from: typeStr))
            return AgentMcpEntry(portable: portable, enabled: true,
                                 agentLocalFields: agentLocal, unparsableReason: nil)
        }
        guard let command = def["command"] as? String else {
            return AgentMcpEntry(portable: nil, enabled: true, agentLocalFields: agentLocal,
                                 unparsableReason: "no command or url")
        }
        let portable = PortableMcpDefinition(
            kind: .stdio, command: command, args: stringArray(def["args"]),
            env: envMap(def["env"], dialect: .dollar), cwd: def["cwd"] as? String,
            url: nil, remoteTransport: nil)
        return AgentMcpEntry(portable: portable, enabled: true,
                             agentLocalFields: agentLocal, unparsableReason: nil)
    }

    /// Codex: stdio `command`/`args`/`env` (literal values), remote inferred from `url`
    /// (streamable-HTTP only). Disable via `enabled = false`.
    private static func normalizeCodex(_ def: [String: Any]) -> AgentMcpEntry {
        let agentLocal = ["bearer_token_env_var", "bearers", "http_headers", "env_http_headers", "env_vars"]
            .filter { def[$0] != nil }
        let enabled = (def["enabled"] as? Bool) ?? true

        if let url = def["url"] as? String {
            let portable = PortableMcpDefinition(
                kind: .remote, command: nil, args: [], env: [:], cwd: nil,
                url: url, remoteTransport: .streamableHttp)
            return AgentMcpEntry(portable: portable, enabled: enabled,
                                 agentLocalFields: agentLocal, unparsableReason: nil)
        }
        guard let command = def["command"] as? String else {
            return AgentMcpEntry(portable: nil, enabled: enabled, agentLocalFields: agentLocal,
                                 unparsableReason: "no command or url")
        }
        let portable = PortableMcpDefinition(
            kind: .stdio, command: command, args: stringArray(def["args"]),
            env: envMap(def["env"], dialect: .literal), cwd: def["cwd"] as? String,
            url: nil, remoteTransport: nil)
        return AgentMcpEntry(portable: portable, enabled: enabled,
                             agentLocalFields: agentLocal, unparsableReason: nil)
    }

    /// opencode: `type:"local"` with `command:[cmd,...args]` (MERGED array) + `environment`
    /// (full word), or `type:"remote"` with `url`. Interpolation dialect `{env:VAR}`.
    /// Disable: v1 `enabled:false`, v2 `disabled:true`.
    private static func normalizeOpencode(_ def: [String: Any], schema: OpencodeSchema) -> AgentMcpEntry {
        let agentLocal = ["headers"].filter { def[$0] != nil }
        let enabled: Bool
        switch schema {
        case .v1: enabled = (def["enabled"] as? Bool) ?? true
        case .v2: enabled = !((def["disabled"] as? Bool) ?? false)
        }

        let type = (def["type"] as? String)?.lowercased()
        if type == "remote" || def["url"] != nil {
            let portable = PortableMcpDefinition(
                kind: .remote, command: nil, args: [], env: [:], cwd: nil,
                url: def["url"] as? String, remoteTransport: .http)
            return AgentMcpEntry(portable: portable, enabled: enabled,
                                 agentLocalFields: agentLocal, unparsableReason: nil)
        }
        // local: command is a single array merging command + args.
        let merged = stringArray(def["command"])
        guard let command = merged.first else {
            return AgentMcpEntry(portable: nil, enabled: enabled, agentLocalFields: agentLocal,
                                 unparsableReason: "empty command array")
        }
        let portable = PortableMcpDefinition(
            kind: .stdio, command: command, args: Array(merged.dropFirst()),
            env: envMap(def["environment"], dialect: .opencode), cwd: def["cwd"] as? String,
            url: nil, remoteTransport: nil)
        return AgentMcpEntry(portable: portable, enabled: enabled,
                             agentLocalFields: agentLocal, unparsableReason: nil)
    }

    // MARK: - Field helpers

    private static func isRemoteType(_ t: String?) -> Bool {
        guard let t else { return false }
        return ["http", "streamable-http", "streamable_http", "sse", "ws"].contains(t)
    }

    private static func remoteTransport(from t: String?) -> McpTransport {
        switch t {
        case "sse": return .sse
        case "ws": return .ws
        case "streamable-http", "streamable_http": return .streamableHttp
        default: return .http
        }
    }

    private static func stringArray(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let a = v as? [Any] { return a.compactMap { $0 as? String } }
        return []
    }

    private static func envMap(_ v: Any?, dialect: McpValueExpr.Dialect) -> [String: McpValueExpr] {
        guard let dict = v as? [String: Any] else { return [:] }
        var out: [String: McpValueExpr] = [:]
        for (k, raw) in dict {
            let s = (raw as? String) ?? String(describing: raw)
            out[k] = McpValueExpr.parse(s, dialect: dialect)
        }
        return out
    }

    // MARK: - JSONC

    /// Strip `//` and `/* */` comments and trailing commas, respecting string literals, so
    /// an opencode `.jsonc` can be fed to `JSONSerialization`. Read-only; never written back.
    static func stripJsonc(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let s = Array(text.unicodeScalars)
        var i = 0
        var inString = false
        while i < s.count {
            let c = s[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < s.count { out.append(s[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                i += 2
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return stripTrailingCommas(String(out))
    }

    /// Remove commas that immediately precede `}` or `]` (whitespace allowed between),
    /// respecting strings. Cheap second pass over the comment-free text.
    private static func stripTrailingCommas(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var keep = [Bool](repeating: true, count: s.count)
        var inString = false
        var i = 0
        while i < s.count {
            let c = s[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; i += 1; continue }
            if c == "," {
                var j = i + 1
                while j < s.count, s[j] == " " || s[j] == "\t" || s[j] == "\n" || s[j] == "\r" { j += 1 }
                if j < s.count, s[j] == "}" || s[j] == "]" { keep[i] = false }
            }
            i += 1
        }
        var out = String.UnicodeScalarView()
        for k in 0..<s.count where keep[k] { out.append(s[k]) }
        return String(out)
    }
}
