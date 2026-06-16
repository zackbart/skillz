import Foundation

/// A small, defensive, READ-ONLY TOML decoder — enough to pull a Codex `config.toml`'s
/// `[mcp_servers.*]` tables into a nested `[String: Any]`, while parsing the rest of the
/// file well enough not to be fooled by it (multiline strings that contain `[`, comments,
/// inline tables, arrays spanning lines, array-of-tables elsewhere).
///
/// It is deliberately NOT a full TOML implementation. Anything it doesn't understand makes
/// it `throw` — and the codec turns that into a `.malformed` result, which the scanner
/// surfaces and the writer refuses to touch. Failing closed is the correct, safe outcome:
/// phase 1 never writes, and the writer (phase 2) does textual block-replace, not a
/// re-render through this reader.
///
/// Values decode to: `String`, `Bool`, `Int`, `Double`, `[Any]`, `[String: Any]`
/// (inline / sub-tables), and `[[String: Any]]` (array-of-tables).
enum TomlMiniReader {
    struct ParseError: Error { let message: String }

    static func parse(_ text: String) throws -> [String: Any] {
        let parser = Parser(Array(text.unicodeScalars))
        return try parser.parseDocument()
    }

    // A mutable tree so table headers can re-point "current table" cheaply.
    private final class Node {
        var values: [String: Any] = [:]          // values may hold Node / [Node] / scalars / [Any]
    }

    private final class Parser {
        private let s: [Unicode.Scalar]
        private var i = 0
        private let root = Node()
        private var current: Node

        init(_ scalars: [Unicode.Scalar]) {
            s = scalars
            current = root
        }

        func parseDocument() throws -> [String: Any] {
            while true {
                skipWhitespaceAndComments(newlines: true)
                if atEnd { break }
                if peek() == "[" {
                    try parseTableHeader()
                } else {
                    try parseKeyValue(into: current)
                    skipInlineSpace()
                    skipCommentToEOL()
                    try expectLineEndOrEOF()
                }
            }
            return materialize(root)
        }

        // MARK: tables

        private func parseTableHeader() throws {
            advance() // [
            let isArray = (peek() == "[")
            if isArray { advance() }
            let path = try parseKeyPath()
            skipInlineSpace()
            try expect("]")
            if isArray { try expect("]") }
            skipInlineSpace(); skipCommentToEOL(); try expectLineEndOrEOF()

            // Navigate/create from root.
            var node = root
            for (idx, key) in path.enumerated() {
                let isLast = idx == path.count - 1
                if isLast && isArray {
                    var arr = (node.values[key] as? [Node]) ?? []
                    let fresh = Node()
                    arr.append(fresh)
                    node.values[key] = arr
                    node = fresh
                } else {
                    node = try descend(node, key)
                }
            }
            current = node
        }

        /// Descend into a child table, creating it if absent. If the slot holds an
        /// array-of-tables, the last element is the active table.
        private func descend(_ node: Node, _ key: String) throws -> Node {
            if let existing = node.values[key] {
                if let child = existing as? Node { return child }
                if let arr = existing as? [Node], let last = arr.last { return last }
                throw ParseError(message: "key '\(key)' is not a table")
            }
            let child = Node()
            node.values[key] = child
            return child
        }

        // MARK: key/value

        private func parseKeyValue(into node: Node) throws {
            let path = try parseKeyPath()
            skipInlineSpace()
            try expect("=")
            skipInlineSpace()
            let value = try parseValue()
            // Dotted key x.y = v → create intermediate tables.
            var target = node
            for key in path.dropLast() { target = try descend(target, key) }
            target.values[path.last!] = value
        }

        /// A dotted key path: bare or quoted segments separated by `.`.
        private func parseKeyPath() throws -> [String] {
            var keys: [String] = []
            while true {
                skipInlineSpace()
                keys.append(try parseKeySegment())
                skipInlineSpace()
                if peek() == "." { advance(); continue }
                break
            }
            return keys
        }

        private func parseKeySegment() throws -> String {
            guard let c = peek() else { throw ParseError(message: "expected key") }
            if c == "\"" || c == "'" { return try parseQuotedString() }
            var out = ""
            while let c = peek(), isBareKeyChar(c) { out.unicodeScalars.append(c); advance() }
            if out.isEmpty { throw ParseError(message: "empty key") }
            return out
        }

        private func parseValue() throws -> Any {
            guard let c = peek() else { throw ParseError(message: "expected value") }
            switch c {
            case "\"", "'": return try parseString()
            case "[": return try parseArray()
            case "{": return try parseInlineTable()
            default: return try parseScalar()
            }
        }

        // MARK: strings

        private func parseString() throws -> String {
            // Triple-quoted multiline?
            if matches("\"\"\"") { return try parseMultiline(delim: "\"", basic: true) }
            if matches("'''") { return try parseMultiline(delim: "'", basic: false) }
            return try parseQuotedString()
        }

        private func parseQuotedString() throws -> String {
            let quote = peek()!
            let basic = (quote == "\"")
            advance()
            var out = ""
            while let c = peek() {
                if c == "\\" && basic {
                    advance()
                    out.unicodeScalars.append(try parseEscape())
                    continue
                }
                if c == quote { advance(); return out }
                if c == "\n" { throw ParseError(message: "unterminated string") }
                out.unicodeScalars.append(c); advance()
            }
            throw ParseError(message: "unterminated string")
        }

        private func parseMultiline(delim: Unicode.Scalar, basic: Bool) throws -> String {
            // Opening triple-delim already consumed by `matches`.
            // A newline immediately after the opening delimiter is trimmed (TOML rule).
            if peek() == "\n" { advance() }
            else if peek() == "\r", peekAt(1) == "\n" { advance(); advance() }
            var out = ""
            while !atEnd {
                if matches(String(repeating: String(delim), count: 3)) { return out }
                let c = peek()!
                if c == "\\" && basic {
                    // Line-ending backslash trims following whitespace; otherwise normal escape.
                    advance()
                    if let n = peek(), n == "\n" || n == "\r" || n == " " || n == "\t" {
                        skipWhitespaceAndComments(newlines: true)
                        continue
                    }
                    out.unicodeScalars.append(try parseEscape())
                    continue
                }
                out.unicodeScalars.append(c); advance()
            }
            throw ParseError(message: "unterminated multiline string")
        }

        private func parseEscape() throws -> Unicode.Scalar {
            guard let c = peek() else { throw ParseError(message: "dangling escape") }
            advance()
            switch c {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "u", "U":
                let count = (c == "u") ? 4 : 8
                var hex = ""
                for _ in 0..<count {
                    guard let h = peek(), isHex(h) else { throw ParseError(message: "bad unicode escape") }
                    hex.unicodeScalars.append(h); advance()
                }
                guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else {
                    throw ParseError(message: "bad unicode scalar")
                }
                return scalar
            default:
                throw ParseError(message: "unknown escape \\\(c)")
            }
        }

        // MARK: arrays / inline tables

        private func parseArray() throws -> [Any] {
            advance() // [
            var out: [Any] = []
            while true {
                skipWhitespaceAndComments(newlines: true)
                if peek() == "]" { advance(); return out }
                if atEnd { throw ParseError(message: "unterminated array") }
                out.append(try parseValue())
                skipWhitespaceAndComments(newlines: true)
                if peek() == "," { advance(); continue }
                if peek() == "]" { advance(); return out }
                throw ParseError(message: "expected , or ] in array")
            }
        }

        private func parseInlineTable() throws -> [String: Any] {
            advance() // {
            let node = Node()
            skipInlineSpace()
            if peek() == "}" { advance(); return materialize(node) }
            while true {
                skipInlineSpace()
                try parseKeyValue(into: node)
                skipInlineSpace()
                if peek() == "," { advance(); continue }
                if peek() == "}" { advance(); return materialize(node) }
                throw ParseError(message: "expected , or } in inline table")
            }
        }

        // MARK: scalars (bool / number / leave-as-string for datetimes etc.)

        private func parseScalar() throws -> Any {
            var tok = ""
            while let c = peek(), !isScalarTerminator(c) { tok.unicodeScalars.append(c); advance() }
            let t = tok.trimmingCharacters(in: .whitespaces)
            if t == "true" { return true }
            if t == "false" { return false }
            let cleaned = t.replacingOccurrences(of: "_", with: "")
            if let int = Int(cleaned) { return int }
            if let dbl = Double(cleaned) { return dbl }
            if t.isEmpty { throw ParseError(message: "empty value") }
            // Datetimes and anything else: keep the literal text (we don't need to interpret it).
            return t
        }

        // MARK: scanning helpers

        private var atEnd: Bool { i >= s.count }
        private func peek() -> Unicode.Scalar? { i < s.count ? s[i] : nil }
        private func peekAt(_ n: Int) -> Unicode.Scalar? { i + n < s.count ? s[i + n] : nil }
        private func advance() { i += 1 }

        private func matches(_ str: String) -> Bool {
            let scalars = Array(str.unicodeScalars)
            guard i + scalars.count <= s.count else { return false }
            for (k, sc) in scalars.enumerated() where s[i + k] != sc { return false }
            i += scalars.count
            return true
        }

        private func expect(_ ch: Unicode.Scalar) throws {
            guard peek() == ch else { throw ParseError(message: "expected '\(ch)'") }
            advance()
        }

        private func expectLineEndOrEOF() throws {
            skipInlineSpace()
            if atEnd { return }
            if peek() == "\n" { advance(); return }
            if peek() == "\r", peekAt(1) == "\n" { advance(); advance(); return }
            throw ParseError(message: "expected end of line")
        }

        private func skipInlineSpace() {
            while let c = peek(), c == " " || c == "\t" { advance() }
        }

        private func skipCommentToEOL() {
            if peek() == "#" { while let c = peek(), c != "\n" { advance() } }
        }

        private func skipWhitespaceAndComments(newlines: Bool) {
            while let c = peek() {
                if c == " " || c == "\t" || c == "\r" { advance() }
                else if newlines && c == "\n" { advance() }
                else if c == "#" { while let c = peek(), c != "\n" { advance() } }
                else { break }
            }
        }

        private func isScalarTerminator(_ c: Unicode.Scalar) -> Bool {
            c == "," || c == "]" || c == "}" || c == "\n" || c == "\r" || c == "#"
        }
        private func isBareKeyChar(_ c: Unicode.Scalar) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }
        private func isHex(_ c: Unicode.Scalar) -> Bool {
            (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
        }

        private func materialize(_ node: Node) -> [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in node.values {
                if let n = v as? Node { out[k] = materialize(n) }
                else if let arr = v as? [Node] { out[k] = arr.map { materialize($0) } }
                else { out[k] = v }
            }
            return out
        }
    }
}
