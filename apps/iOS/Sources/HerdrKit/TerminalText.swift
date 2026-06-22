import Foundation

/// Projects raw terminal output into a readable mobile transcript: drops the
/// box-drawing frames a TUI agent (Claude Code, etc.) draws for a wide grid,
/// unwraps `│ content │` side borders, collapses blank runs, and de-duplicates
/// the current-screen footer that both `recent` and `detection` reads contain.
///
/// Color is *not* touched here — these functions preserve any ANSI SGR escapes
/// inside the kept text so the UI can still colorize it; ANSI is only stripped
/// internally for classification/comparison. Pure Foundation, so it unit-tests
/// on Linux alongside the rest of HerdrKit.
public enum TerminalText {
    private static let ansiPattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"

    /// Strip ANSI/VT escape sequences — used to inspect a line's visible text.
    public static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
    }

    /// A line whose visible text is nothing but frame/rule characters (box
    /// drawing, or a run of `-`/`=`/`_`) — i.e. a border or horizontal rule we
    /// drop entirely on mobile.
    public static func isFramingLine(_ visible: String) -> Bool {
        let t = visible.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return false }
        return t.unicodeScalars.allSatisfy { s in
            (0x2500...0x257F).contains(s.value) // box drawing
                || s == "-" || s == "=" || s == "_" || s == " "
        }
    }

    /// If a line is framed as `│ content │`, drop the outer borders and one pad
    /// space on each side, preserving inner ANSI. Lines without matching side
    /// borders are returned unchanged.
    public static func unwrapSides(_ raw: String) -> String {
        let v = stripANSI(raw).trimmingCharacters(in: .whitespaces)
        guard let first = v.first, let last = v.last,
              "│┃|".contains(first), "│┃|".contains(last), v.count >= 2 else { return raw }
        let ansi = "(?:\(ansiPattern))*"
        var s = raw.replacingOccurrences(
            of: "^\\s*\(ansi)[│┃|]\\s?", with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: "\\s?[│┃|]\(ansi)\\s*$", with: "", options: .regularExpression)
        return s
    }

    /// Clean a block for mobile reading: drop framing lines, unwrap side borders,
    /// right-trim grid padding, and collapse runs of blank lines (and leading /
    /// trailing blanks) so the transcript reads without the grid's empty space.
    public static func clean(_ lines: [String]) -> [String] {
        var out: [String] = []
        var pendingBlank = false
        for raw in lines {
            let visible = stripANSI(raw)
            if visible.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingBlank = !out.isEmpty
                continue
            }
            if isFramingLine(visible) { continue }
            var line = unwrapSides(raw)
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            if pendingBlank { out.append(""); pendingBlank = false }
            out.append(line)
        }
        return out
    }
}
