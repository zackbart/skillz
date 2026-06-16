import Foundation

/// Codex (`config.toml`) writer. TOML has no closing delimiter for a table, so edits are
/// done textually and precisely: locate the target `[mcp_servers.<name>]` block, re-render
/// only the keys this writer manages, and copy every other line — comments, agent-local
/// keys (`bearer_token_env_var`, `http_headers`, `env_http_headers`, …) and non-`env`
/// subtables — through verbatim. Everything outside the one entry's block is byte-preserved.
///
/// It FAILS CLOSED: if `mcp_servers` is expressed in a shape it can't safely rewrite
/// (top-level dotted keys `mcp_servers.x. …`, an inline `mcp_servers = { … }` table, a plain
/// `[mcp_servers]` table, or an array-of-tables), it refuses to edit and surfaces why,
/// rather than risk corrupting the file.
enum TomlMcpWriter {
    struct WriteError: Error { let message: String }

    static let managedKeys: Set<String> = ["command", "args", "env", "url", "enabled"]

    static func upsert(source: String, name: String,
                       def: PortableMcpDefinition, enabled: Bool) throws -> String {
        try assertSafe(source)
        // An empty/whitespace file starts from no lines, so a fresh block isn't preceded by
        // a spurious blank line.
        var lines = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : source.components(separatedBy: "\n")
        let rendered = renderBlock(name: name, def: def, enabled: enabled)

        if let block = findBlock(lines, name: name) {
            let preserved = preservedLines(lines, block: block, name: name)
            let newBlock = ["[mcp_servers.\(tomlKeySegment(name))]"] + rendered + preserved
            lines.replaceSubrange(block, with: newBlock)
        } else {
            // INSERT: append a fresh block at EOF, separated by one blank line.
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            } else if lines.isEmpty {
                // empty file: no separator needed
            }
            lines.append("[mcp_servers.\(tomlKeySegment(name))]")
            lines.append(contentsOf: rendered)
        }
        return lines.joined(separator: "\n")
    }

    static func remove(source: String, name: String) throws -> String {
        try assertSafe(source)
        var lines = source.components(separatedBy: "\n")
        guard let block = findBlock(lines, name: name) else { return source }
        // Also swallow a single trailing blank line so blocks don't accumulate gaps.
        var upper = block.upperBound
        if upper < lines.count, lines[upper].trimmingCharacters(in: .whitespaces).isEmpty { upper += 1 }
        lines.removeSubrange(block.lowerBound..<upper)
        return lines.joined(separator: "\n")
    }

    // MARK: - Fail-closed guard

    private static func assertSafe(_ source: String) throws {
        var atRoot = true
        for raw in source.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if t.hasPrefix("[") {
                let (path, isArray) = parseHeader(t)
                if path == "mcp_servers" {
                    throw WriteError(message: "refusing to edit: a plain [mcp_servers] table is present — rewrite it as [mcp_servers.<name>] entries first")
                }
                if isArray, path.hasPrefix("mcp_servers") {
                    throw WriteError(message: "refusing to edit: mcp_servers uses an array-of-tables form this editor can't safely rewrite")
                }
                atRoot = false
            } else if atRoot {
                // A root-scope assignment to mcp_servers in dotted or inline form is unsafe.
                if t.hasPrefix("mcp_servers") {
                    let after = t.dropFirst("mcp_servers".count).drop(while: { $0 == " " })
                    if after.first == "." || after.first == "=" {
                        throw WriteError(message: "refusing to edit: mcp_servers uses a dotted/inline key form this editor can't safely rewrite")
                    }
                }
            }
        }
    }

    // MARK: - Block location

    /// The line range of `[mcp_servers.<name>]` and all of its subtables.
    private static func findBlock(_ lines: [String], name: String) -> Range<Int>? {
        let target = "mcp_servers.\(name)"
        guard let start = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[") else { return false }
            let (path, isArray) = parseHeader(t)
            return !isArray && path == target
        }) else { return nil }

        var end = start + 1
        while end < lines.count {
            let t = lines[end].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                let (path, _) = parseHeader(t)
                // A subtable of this entry stays in the block; any other table ends it.
                if path == target || path.hasPrefix(target + ".") { end += 1; continue }
                break
            }
            end += 1
        }
        return start..<end
    }

    /// Lines inside the block to keep verbatim: comments, blank lines, unmanaged entry-level
    /// keys, and every subtable except `env` (which this writer re-renders inline).
    private static func preservedLines(_ lines: [String], block: Range<Int>, name: String) -> [String] {
        let target = "mcp_servers.\(name)"
        var out: [String] = []
        var i = block.lowerBound + 1 // skip the header itself
        while i < block.upperBound {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                // a subtable group: header + body until next header / block end
                let subStart = i
                let (path, _) = parseHeader(t)
                let sub = String(path.dropFirst(min(path.count, (target + ".").count)))
                let subKey = sub.split(separator: ".").first.map(String.init) ?? sub
                i += 1
                while i < block.upperBound, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") { i += 1 }
                if subKey != "env" {
                    out.append(contentsOf: lines[subStart..<i])
                } else {
                    // Re-rendered inline, so the subtable is dropped — but keep its trailing
                    // blank line(s), which separate this entry from the next table.
                    var j = i
                    while j > subStart, lines[j - 1].trimmingCharacters(in: .whitespaces).isEmpty { j -= 1 }
                    out.append(contentsOf: lines[j..<i])
                }
            } else if t.isEmpty || t.hasPrefix("#") {
                out.append(line); i += 1
            } else {
                // entry-level key = value, possibly spanning lines (balance [] {})
                let grpStart = i
                var bal = bracketBalance(line)
                i += 1
                while i < block.upperBound, bal > 0 {
                    bal += bracketBalance(lines[i]); i += 1
                }
                let key = keyName(line)
                if !managedKeys.contains(key) { out.append(contentsOf: lines[grpStart..<i]) }
            }
        }
        return out
    }

    // MARK: - Rendering

    private static func renderBlock(name: String, def: PortableMcpDefinition, enabled: Bool) -> [String] {
        var out: [String] = []
        switch def.kind {
        case .remote:
            if let u = def.url { out.append("url = \(tomlString(u))") }
        case .stdio:
            if let c = def.command { out.append("command = \(tomlString(c))") }
            if !def.args.isEmpty { out.append("args = \(tomlArray(def.args))") }
            if !def.env.isEmpty { out.append("env = \(tomlInlineTable(def.env))") }
        }
        if !enabled { out.append("enabled = false") }
        return out
    }

    // MARK: - TOML literal helpers

    private static func tomlString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04X", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    private static func tomlArray(_ items: [String]) -> String {
        "[" + items.map { tomlString($0) }.joined(separator: ", ") + "]"
    }

    private static func tomlInlineTable(_ env: [String: McpValueExpr]) -> String {
        let body = env.keys.sorted().map { k in
            "\(tomlKeySegment(k)) = \(tomlString(exprLiteral(env[k]!)))"
        }.joined(separator: ", ")
        return "{ \(body) }"
    }

    /// Codex values are literal TOML strings — render the typed expression back to text.
    private static func exprLiteral(_ e: McpValueExpr) -> String {
        switch e {
        case .literal(let s): return s
        case .envVar(let v): return "${\(v)}"
        case .envVarDefault(let v, let d): return "${\(v):-\(d)}"
        case .fileRef(let p): return p
        }
    }

    /// A TOML key segment: bare if it's a valid bare key, otherwise a quoted key.
    private static func tomlKeySegment(_ s: String) -> String {
        let bare = !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return bare ? s : tomlString(s)
    }

    // MARK: - Parsing helpers

    /// `[a.b.c]` / `[[a.b]]` → (path, isArray). Stops at the first `]`, ignoring comments.
    private static func parseHeader(_ t: String) -> (path: String, isArray: Bool) {
        var s = Substring(t)
        var isArray = false
        if s.hasPrefix("[[") { isArray = true; s = s.dropFirst(2) }
        else if s.hasPrefix("[") { s = s.dropFirst(1) }
        if let close = s.firstIndex(of: "]") { s = s[s.startIndex..<close] }
        return (s.trimmingCharacters(in: .whitespaces), isArray)
    }

    private static func keyName(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        var out = ""
        for ch in t {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { out.append(ch) }
            else { break }
        }
        return out
    }

    /// Net bracket/brace depth on a line, ignoring brackets inside TOML strings.
    private static func bracketBalance(_ line: String) -> Int {
        var depth = 0
        var inBasic = false, inLiteral = false
        var prevBackslash = false
        for ch in line {
            if inBasic {
                if ch == "\"" && !prevBackslash { inBasic = false }
                prevBackslash = (ch == "\\" && !prevBackslash)
                continue
            }
            if inLiteral { if ch == "'" { inLiteral = false }; continue }
            switch ch {
            case "\"": inBasic = true; prevBackslash = false
            case "'": inLiteral = true
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            case "#": return depth // rest is a comment
            default: break
            }
        }
        return depth
    }
}
