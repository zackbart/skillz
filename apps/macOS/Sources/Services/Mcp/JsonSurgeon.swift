import Foundation

/// Byte-level, format-preserving JSON / JSONC editor. It scans the source to locate the
/// exact scalar range of one object member (or its value), then splices ONLY that range —
/// every comment, trailing comma, key order and indentation outside the touched member is
/// preserved verbatim. It never round-trips through `JSONSerialization` (which would discard
/// all of that), and it never re-renders a whole object it wasn't asked to change.
///
/// Works on `[Unicode.Scalar]` with `Int` indices so splices are trivial and lossless.
/// Tolerates JSONC (`//`, `/* */`, trailing commas) while scanning, so it is safe on both
/// strict `.json` (Claude / Cursor) and `.jsonc` (opencode).
enum JsonSurgeon {
    struct SurgeonError: Error { let message: String }

    // MARK: - Public model

    /// A located object member: the spans of its key, its value, and the full member
    /// (key-start … value-end, excluding any trailing comma / surrounding whitespace).
    struct Member {
        let key: String
        let valueRange: Range<Int>
        let memberRange: Range<Int>
    }

    /// The content object found at a key path: the index of its `{` and its members.
    struct Located {
        let braceOpen: Int          // index of `{`
        let braceClose: Int         // index of matching `}`
        let members: [Member]
    }

    // MARK: - Navigation

    /// Locate the object reached by following `keyPath` from the document root. Returns nil
    /// if any segment is absent (a legitimate "not here yet"), throws only on malformed JSON.
    static func locate(_ source: String, keyPath: [String]) throws -> Located? {
        let s = Array(source.unicodeScalars)
        var i = skipTrivia(s, 0)
        guard i < s.count, s[i] == "{" else {
            if i >= s.count { return nil }            // empty document → nothing to locate
            throw SurgeonError(message: "root is not a JSON object")
        }
        var objStart = i
        var path = keyPath
        while true {
            let located = try readObject(s, objStart)
            guard let seg = path.first else { return located }
            path.removeFirst()
            guard let m = located.members.first(where: { $0.key == seg }) else { return nil }
            i = skipTrivia(s, m.valueRange.lowerBound)
            guard i < s.count, s[i] == "{" else { return nil } // value isn't an object
            objStart = i
        }
    }

    // MARK: - Edits (each returns the full new document text)

    /// Replace `key`'s value with `valueText`, or insert the member if absent. `valueText`
    /// must be a fully-rendered JSON value at the correct indentation depth.
    static func upsertMember(_ source: String, keyPath: [String], key: String,
                             valueText: String, indentUnit: String = "  ") throws -> String {
        let s = Array(source.unicodeScalars)
        guard let located = try locate(source, keyPath: keyPath) else {
            throw SurgeonError(message: "container \(keyPath.joined(separator: ".")) not found")
        }
        if let m = located.members.first(where: { $0.key == key }) {
            return splice(s, m.valueRange, with: valueText)
        }
        return insertMember(s, into: located, key: key, valueText: valueText, indentUnit: indentUnit)
    }

    /// Remove `key` from the object at `keyPath`. No-op (returns source) if already absent.
    static func removeMember(_ source: String, keyPath: [String], key: String) throws -> String {
        let s = Array(source.unicodeScalars)
        guard let located = try locate(source, keyPath: keyPath),
              let idx = located.members.firstIndex(where: { $0.key == key }) else { return source }
        let m = located.members[idx]

        // Extend the cut to swallow exactly one separating comma + the whitespace/newline of
        // the member's own line, so neither a dangling comma nor a blank line is left behind.
        var lo = lineStart(s, m.memberRange.lowerBound)
        var hi = m.memberRange.upperBound
        // trailing comma after the value?
        let j = skipTrivia(s, hi)
        if j < s.count, s[j] == "," {
            hi = j + 1
            // consume to end of that line (incl. newline) so the line vanishes cleanly
            var k = hi
            while k < s.count, s[k] == " " || s[k] == "\t" { k += 1 }
            if k < s.count, s[k] == "\r" { k += 1 }
            if k < s.count, s[k] == "\n" { k += 1; hi = k }
        } else {
            // Last member: drop the PRECEDING comma (and the whitespace/newline between it
            // and this member), but LEAVE this member's own trailing newline so the closing
            // brace stays on its own line.
            var p = lo - 1
            while p >= 0, s[p] == " " || s[p] == "\t" || s[p] == "\n" || s[p] == "\r" { p -= 1 }
            if p >= 0, s[p] == "," { lo = p }
        }
        var out = s
        out.removeSubrange(lo..<hi)
        return String(String.UnicodeScalarView(out))
    }

    // MARK: - Member insertion

    private static func insertMember(_ s: [Unicode.Scalar], into located: Located,
                                     key: String, valueText: String, indentUnit: String) -> String {
        let keyJson = renderJsonString(key)
        if located.members.isEmpty {
            // Expand `{}` (in any inline form) into a two-line object.
            let closeIndent = leadingIndentString(s, located.braceOpen)
            let memberIndent = closeIndent + indentUnit
            let body = "{\n\(memberIndent)\(keyJson): \(valueText)\n\(closeIndent)}"
            return splice(s, located.braceOpen..<(located.braceClose + 1), with: body)
        }
        // Insert after the last member, matching its indentation.
        let last = located.members[located.members.count - 1]
        let memberIndent = leadingIndentString(s, last.memberRange.lowerBound)
        // Insertion point: right after the last member's value (before any trailing comma).
        let insertAt = last.valueRange.upperBound
        // Is there already a trailing comma between last value and `}`?
        let j = skipTrivia(s, insertAt)
        let hasTrailingComma = (j < s.count && s[j] == ",")
        let prefix = hasTrailingComma ? "" : ","
        let addition = "\(prefix)\n\(memberIndent)\(keyJson): \(valueText)"
        return splice(s, insertAt..<insertAt, with: addition)
    }

    // MARK: - Object reader

    private static func readObject(_ s: [Unicode.Scalar], _ open: Int) throws -> Located {
        var i = open + 1
        var members: [Member] = []
        while true {
            i = skipTrivia(s, i)
            guard i < s.count else { throw SurgeonError(message: "unterminated object") }
            if s[i] == "}" { return Located(braceOpen: open, braceClose: i, members: members) }
            // key (string)
            guard s[i] == "\"" else { throw SurgeonError(message: "expected string key at \(i)") }
            let keyStart = i
            let keyEnd = try scanString(s, i)
            let key = decodeJsonString(Array(s[keyStart..<keyEnd]))
            i = skipTrivia(s, keyEnd)
            guard i < s.count, s[i] == ":" else { throw SurgeonError(message: "expected ':'") }
            i = skipTrivia(s, i + 1)
            let valStart = i
            let valEnd = try scanValue(s, i)
            members.append(Member(key: key, valueRange: valStart..<valEnd,
                                  memberRange: keyStart..<valEnd))
            i = skipTrivia(s, valEnd)
            if i < s.count, s[i] == "," { i += 1; continue }
            if i < s.count, s[i] == "}" { return Located(braceOpen: open, braceClose: i, members: members) }
            throw SurgeonError(message: "expected ',' or '}' at \(i)")
        }
    }

    // MARK: - Value / token scanners (return end index, exclusive)

    static func scanValue(_ s: [Unicode.Scalar], _ i: Int) throws -> Int {
        guard i < s.count else { throw SurgeonError(message: "expected value") }
        switch s[i] {
        case "{": return try scanBracketed(s, i, open: "{", close: "}")
        case "[": return try scanBracketed(s, i, open: "[", close: "]")
        case "\"": return try scanString(s, i)
        default:
            // number / true / false / null — read until a structural delimiter.
            var j = i
            while j < s.count, !isDelimiter(s[j]) { j += 1 }
            return j
        }
    }

    private static func scanBracketed(_ s: [Unicode.Scalar], _ i: Int,
                                      open: Unicode.Scalar, close: Unicode.Scalar) throws -> Int {
        var depth = 0
        var j = i
        while j < s.count {
            let c = s[j]
            if c == "\"" { j = try scanString(s, j); continue }
            if c == "/" , j + 1 < s.count, s[j + 1] == "/" || s[j + 1] == "*" {
                j = skipTrivia(s, j); continue
            }
            if c == open { depth += 1 }
            else if c == close { depth -= 1; if depth == 0 { return j + 1 } }
            j += 1
        }
        throw SurgeonError(message: "unterminated \(open)")
    }

    private static func scanString(_ s: [Unicode.Scalar], _ i: Int) throws -> Int {
        var j = i + 1
        while j < s.count {
            let c = s[j]
            if c == "\\" { j += 2; continue }
            if c == "\"" { return j + 1 }
            j += 1
        }
        throw SurgeonError(message: "unterminated string")
    }

    // MARK: - Trivia

    static func skipTrivia(_ s: [Unicode.Scalar], _ i: Int) -> Int {
        var j = i
        while j < s.count {
            let c = s[j]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { j += 1 }
            else if c == "/", j + 1 < s.count, s[j + 1] == "/" {
                j += 2; while j < s.count, s[j] != "\n" { j += 1 }
            } else if c == "/", j + 1 < s.count, s[j + 1] == "*" {
                j += 2; while j + 1 < s.count, !(s[j] == "*" && s[j + 1] == "/") { j += 1 }
                j += 2
            } else { break }
        }
        return j
    }

    private static func isDelimiter(_ c: Unicode.Scalar) -> Bool {
        c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\n" || c == "\r" || c == "/"
    }

    // MARK: - Indentation helpers

    private static func lineStart(_ s: [Unicode.Scalar], _ i: Int) -> Int {
        var j = i
        while j > 0, s[j - 1] != "\n" { j -= 1 }
        return j
    }

    /// The whitespace run from the start of `i`'s line up to `i` (the indentation).
    private static func leadingIndentString(_ s: [Unicode.Scalar], _ i: Int) -> String {
        let start = lineStart(s, i)
        var view = String.UnicodeScalarView()
        var j = start
        while j < i, s[j] == " " || s[j] == "\t" { view.append(s[j]); j += 1 }
        return String(view)
    }

    // MARK: - Splice + render

    private static func splice(_ s: [Unicode.Scalar], _ range: Range<Int>, with text: String) -> String {
        var out = s
        out.replaceSubrange(range, with: Array(text.unicodeScalars))
        return String(String.UnicodeScalarView(out))
    }

    /// Render a Swift string as a JSON string literal (minimal, correct escaping).
    static func renderJsonString(_ value: String) -> String {
        var out = "\""
        for ch in value.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
        return out
    }

    /// Decode a JSON string literal's scalars (incl. surrounding quotes) back to a Swift
    /// string — used only for KEY comparison, so it handles the common escapes.
    private static func decodeJsonString(_ scalars: [Unicode.Scalar]) -> String {
        guard scalars.count >= 2 else { return "" }
        var out = String.UnicodeScalarView()
        var i = 1
        let end = scalars.count - 1
        while i < end {
            let c = scalars[i]
            if c == "\\", i + 1 < end {
                let n = scalars[i + 1]
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "u":
                    if i + 5 < end + 1 {
                        let hex = String(String.UnicodeScalarView(scalars[(i + 2)..<min(i + 6, end)]))
                        if let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) { out.append(sc) }
                        i += 6; continue
                    }
                    out.append(n)
                default: out.append(n)
                }
                i += 2; continue
            }
            out.append(c); i += 1
        }
        return String(out)
    }
}
