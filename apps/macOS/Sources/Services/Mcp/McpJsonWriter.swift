import Foundation

/// Renders + applies single-server edits for the JSON-family harnesses (Claude Code,
/// Cursor, opencode) on top of `JsonSurgeon`. It re-renders ONE server's value object (never
/// the whole map) and preserves every member of that object it doesn't itself manage —
/// agent-local auth/header fields (`oauth`, `headers`, `headersHelper`, Cursor `auth`,
/// `envFile`, …) and any unknown keys are copied through verbatim, never stripped.
///
/// Server value objects are rendered single-line, which keeps the output deterministic at any
/// nesting depth (so re-applying the same state is byte-identical) without having to reason
/// about the surrounding file's indentation.
enum McpJsonWriter {
    /// Keys this writer owns and re-renders from the portable definition. Everything else on
    /// an existing entry is preserved verbatim.
    static let managedKeys: Set<String> =
        ["command", "args", "env", "environment", "type", "url", "cwd", "enabled", "disabled"]

    /// Insert or replace `name` in the server map at `keyPath`, creating any missing
    /// containers (and the document itself) along the way.
    static func upsert(source: String, harness: McpHarness, keyPath: [String], name: String,
                       def: PortableMcpDefinition, enabled: Bool, schema: OpencodeSchema) throws -> String {
        let ensured = try ensureContainer(source, keyPath)

        // Preserve members of an existing entry that we don't manage (verbatim source text).
        var preserved: [String] = []
        if let existing = try JsonSurgeon.locate(ensured, keyPath: keyPath + [name]) {
            let s = Array(ensured.unicodeScalars)
            for m in existing.members where !managedKeys.contains(m.key) {
                preserved.append(String(String.UnicodeScalarView(s[m.memberRange])))
            }
        }

        let valueText = renderValue(harness: harness, def: def, enabled: enabled,
                                    schema: schema, preserved: preserved)
        return try JsonSurgeon.upsertMember(ensured, keyPath: keyPath, key: name, valueText: valueText)
    }

    static func remove(source: String, keyPath: [String], name: String) throws -> String {
        try JsonSurgeon.removeMember(source, keyPath: keyPath, key: name)
    }

    // MARK: - Container creation

    /// Ensure every segment of `keyPath` exists as an object, creating empties for the
    /// missing suffix (and starting from `{}` for an empty/whitespace document).
    static func ensureContainer(_ source: String, _ keyPath: [String]) throws -> String {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}\n" : source
        var existing = 0
        while existing < keyPath.count {
            if try JsonSurgeon.locate(src, keyPath: Array(keyPath[0...existing])) != nil { existing += 1 }
            else { break }
        }
        if existing == keyPath.count { return src }
        let parent = Array(keyPath[0..<existing])
        let remaining = Array(keyPath[existing...])
        let value = nestedObject(remaining.dropFirst())
        return try JsonSurgeon.upsertMember(src, keyPath: parent, key: remaining[0], valueText: value)
    }

    private static func nestedObject(_ keys: ArraySlice<String>) -> String {
        guard let first = keys.first else { return "{}" }
        return "{ \(JsonSurgeon.renderJsonString(first)): \(nestedObject(keys.dropFirst())) }"
    }

    // MARK: - Value rendering

    static func renderValue(harness: McpHarness, def: PortableMcpDefinition,
                            enabled: Bool, schema: OpencodeSchema, preserved: [String]) -> String {
        var parts: [String] = []
        switch harness {
        case .claudeCode:
            if def.kind == .remote {
                parts.append(field("type", claudeRemoteType(def.remoteTransport)))
                if let u = def.url { parts.append(field("url", u)) }
            } else {
                parts.append(contentsOf: stdioJsonFields(def, envKey: "env", dialect: .dollar))
            }
        case .cursor:
            if def.kind == .remote {
                if let u = def.url { parts.append(field("url", u)) }   // transport inferred, no type
            } else {
                parts.append(contentsOf: stdioJsonFields(def, envKey: "env", dialect: .dollar))
            }
        case .opencode:
            if def.kind == .remote {
                parts.append(field("type", "remote"))
                if let u = def.url { parts.append(field("url", u)) }
            } else {
                parts.append(field("type", "local"))
                let merged = ([def.command].compactMap { $0 }) + def.args
                parts.append("\"command\": \(renderArray(merged))")
                if !def.env.isEmpty { parts.append("\"environment\": \(renderEnv(def.env, .opencode))") }
                if let cwd = def.cwd { parts.append(field("cwd", cwd)) }
            }
            switch schema {
            case .v1: parts.append("\"enabled\": \(enabled)")
            case .v2: if !enabled { parts.append("\"disabled\": true") }
            }
        case .codex:
            break // handled by the TOML writer
        }
        parts.append(contentsOf: preserved)
        return "{ " + parts.joined(separator: ", ") + " }"
    }

    private static func stdioJsonFields(_ def: PortableMcpDefinition,
                                        envKey: String, dialect: McpValueExpr.Dialect) -> [String] {
        var parts: [String] = []
        if let c = def.command { parts.append(field("command", c)) }
        if !def.args.isEmpty { parts.append("\"args\": \(renderArray(def.args))") }
        if !def.env.isEmpty { parts.append("\"\(envKey)\": \(renderEnv(def.env, dialect))") }
        if let cwd = def.cwd { parts.append(field("cwd", cwd)) }
        return parts
    }

    // MARK: - Render helpers

    private static func field(_ key: String, _ value: String) -> String {
        "\(JsonSurgeon.renderJsonString(key)): \(JsonSurgeon.renderJsonString(value))"
    }

    private static func renderArray(_ items: [String]) -> String {
        "[" + items.map { JsonSurgeon.renderJsonString($0) }.joined(separator: ", ") + "]"
    }

    private static func renderEnv(_ env: [String: McpValueExpr], _ dialect: McpValueExpr.Dialect) -> String {
        let body = env.keys.sorted().map { k in
            "\(JsonSurgeon.renderJsonString(k)): \(JsonSurgeon.renderJsonString(renderExpr(env[k]!, dialect)))"
        }.joined(separator: ", ")
        return "{ \(body) }"
    }

    /// Render a typed interpolation back into a harness's dialect. Cross-dialect features
    /// without an equivalent (opencode has no `:-default`; the `${}` dialects have no
    /// file-ref) degrade to the closest representable form rather than emitting something
    /// the target can't parse.
    private static func renderExpr(_ e: McpValueExpr, _ dialect: McpValueExpr.Dialect) -> String {
        switch dialect {
        case .dollar:
            switch e {
            case .literal(let s): return s
            case .envVar(let v): return "${\(v)}"
            case .envVarDefault(let v, let d): return "${\(v):-\(d)}"
            case .fileRef(let p): return p
            }
        case .opencode:
            switch e {
            case .literal(let s): return s
            case .envVar(let v): return "{env:\(v)}"
            case .envVarDefault(let v, _): return "{env:\(v)}"
            case .fileRef(let p): return "{file:\(p)}"
            }
        case .literal:
            switch e {
            case .literal(let s): return s
            case .envVar(let v): return v
            case .envVarDefault(let v, _): return v
            case .fileRef(let p): return p
            }
        }
    }

    private static func claudeRemoteType(_ t: McpTransport?) -> String {
        switch t {
        case .sse: return "sse"
        case .ws: return "ws"
        case .streamableHttp: return "streamable-http"
        default: return "http"
        }
    }
}
