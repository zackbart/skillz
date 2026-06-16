import Foundation

/// Reads skills.sh lock files into per-skill provenance, keyed by skill name as the
/// lock stores it. Handles both schemas:
///  - global `~/.agents/.skill-lock.json` (v3, `skillFolderHash`, timestamps)
///  - project `<root>/skills-lock.json` (v1, `computedHash`)
/// Best-effort: missing file / unknown keys / schema drift are tolerated.
enum SkillLockReader {
    static func readGlobal() -> [String: SkillProvenance] {
        read(url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/.skill-lock.json"))
    }

    static func readProject(root: URL) -> [String: SkillProvenance] {
        read(url: root.appendingPathComponent("skills-lock.json"))
    }

    static func read(url: URL) -> [String: SkillProvenance] {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let skills = root["skills"] as? [String: Any]
        else { return [:] }

        var out: [String: SkillProvenance] = [:]
        for (name, value) in skills {
            guard let e = value as? [String: Any] else { continue }
            out[name] = SkillProvenance(
                source: e["source"] as? String ?? "",
                sourceURL: e["sourceUrl"] as? String,
                skillPath: e["skillPath"] as? String,
                folderHash: (e["skillFolderHash"] as? String) ?? (e["computedHash"] as? String),
                installedAt: e["installedAt"] as? String,
                updatedAt: e["updatedAt"] as? String,
                pluginName: e["pluginName"] as? String
            )
        }
        return out
    }
}
