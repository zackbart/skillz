import Foundation
import Yams

struct ParsedSkill {
    var frontmatter: [String: Any]
    var rawFrontmatter: String
    var body: String
}

/// Splits a SKILL.md into YAML frontmatter (parsed with Yams) and a markdown body.
/// Tolerates files without frontmatter and unknown/agent-specific keys.
enum FrontmatterParser {
    static func parse(_ content: String) -> ParsedSkill {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else {
            return ParsedSkill(frontmatter: [:], rawFrontmatter: "", body: content)
        }

        let lines = normalized.components(separatedBy: "\n")
        // Line 0 is the opening "---"; find the closing fence.
        var closing: Int?
        var i = 1
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closing = i
                break
            }
            i += 1
        }

        guard let end = closing else {
            return ParsedSkill(frontmatter: [:], rawFrontmatter: "", body: content)
        }

        let rawFrontmatter = lines[1..<end].joined(separator: "\n")
        let body = end + 1 < lines.count ? lines[(end + 1)...].joined(separator: "\n") : ""

        var frontmatter: [String: Any] = [:]
        if let loaded = try? Yams.load(yaml: rawFrontmatter) as? [String: Any] {
            frontmatter = loaded
        }

        return ParsedSkill(
            frontmatter: frontmatter,
            rawFrontmatter: rawFrontmatter,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
