import Foundation

/// Discovers skills on disk and enriches them with provenance, declared agents,
/// git status, CLI-managed and diverged flags. Identity is the canonical
/// (symlink-resolved) directory; the same canonical skill referenced by several
/// agents collapses into one `Skill` with the union of `wiredAgents`.
enum SkillScanner {
    static func scanGlobal() -> [Skill] {
        scan(
            scope: .global,
            dirs: Agent.allCases.map { agent in (agent, agent.globalSkillDirs) },
            lock: SkillLockReader.readGlobal(),
            declared: declaredByPath(SkillsCLIService.listGlobalJSON())
        )
    }

    static func scanProject(root: URL) -> [Skill] {
        var dirs: [(Agent, [URL])] = []
        for base in projectBases(from: root) {
            for agent in Agent.allCases {
                dirs.append((agent, agent.projectSkillDirs.map { base.appendingPathComponent($0) }))
            }
        }
        return scan(
            scope: .project(root: root.path),
            dirs: dirs,
            lock: SkillLockReader.readProject(root: root),
            declared: declaredByPath(SkillsCLIService.listProjectJSON(in: root))
        )
    }

    // MARK: - Core

    private static func scan(
        scope: ResourceScope,
        dirs: [(Agent, [URL])],
        lock: [String: SkillProvenance],
        declared: [String: Set<Agent>]
    ) -> [Skill] {
        let fm = FileManager.default
        var byCanonical: [String: Skill] = [:]
        var linkPaths: [String: Set<String>] = [:] // canonicalPath -> entry (possibly symlink) paths

        for (agent, agentDirs) in dirs {
            for dir in agentDirs {
                guard let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
                ) else { continue }

                for entry in entries {
                    let skillMd = entry.appendingPathComponent("SKILL.md")
                    guard fm.fileExists(atPath: skillMd.path) else { continue }

                    // Is this entry an actual symlink (→ canonical store), or a real directory
                    // living in the agent's own dir? lstat via attributesOfItem (doesn't follow).
                    let attrs = try? fm.attributesOfItem(atPath: entry.path)
                    let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink

                    let canonical = entry.resolvingSymlinksInPath()
                    let key = canonical.path
                    linkPaths[key, default: []].insert(entry.path)

                    if byCanonical[key] != nil {
                        byCanonical[key]?.wiredAgents.insert(agent)
                        if isLink { byCanonical[key]?.symlinkedAgents.insert(agent) }
                        continue
                    }

                    let canonicalMd = canonical.appendingPathComponent("SKILL.md")
                    let content = (try? String(contentsOf: canonicalMd, encoding: .utf8)) ?? ""
                    let parsed = FrontmatterParser.parse(content)
                    let basename = canonical.lastPathComponent
                    let name = (parsed.frontmatter["name"] as? String) ?? basename
                    // Per-canonical provenance: lock files key by the dir name under skills/,
                    // so match strictly by basename — avoids cross-contaminating diverged
                    // same-name copies (a name-keyed fallback would reintroduce that bug).
                    let prov = lock[basename]

                    var skill = Skill(
                        canonicalPath: key,
                        scope: scope,
                        name: name,
                        directoryURL: canonical,
                        skillMdURL: canonicalMd,
                        summary: parsed.frontmatter["description"] as? String,
                        bodyMarkdown: parsed.body,
                        frontmatterKeys: parsed.frontmatter.keys.sorted(),
                        rawFrontmatter: parsed.rawFrontmatter,
                        wiredAgents: [agent],
                        provenance: prov
                    )
                    skill.isCLIManaged = (prov != nil)
                    if isLink { skill.symlinkedAgents = [agent] }
                    skill.declaredAgents = declared[key] ?? []
                    skill.bundledFiles = bundledFiles(in: canonical, fm: fm)
                    skill.searchHaystack =
                        (name + " " + (skill.summary ?? "") + " " + parsed.body).lowercased()
                    byCanonical[key] = skill
                }
            }
        }

        return finalize(byCanonical, linkPaths: linkPaths, projectRoot: scope.projectRoot)
    }

    private static func finalize(
        _ byCanonical: [String: Skill],
        linkPaths: [String: Set<String>],
        projectRoot: String?
    ) -> [Skill] {
        var skills = Array(byCanonical.values)

        // Git status — classify canonical dirs + their (unresolved) link paths in one batch.
        var allPaths = Set(byCanonical.keys)
        for (_, links) in linkPaths { allPaths.formUnion(links) }
        let git = GitStatusService.classify(paths: Array(allPaths))

        // Project-relative locations, from the (unresolved) reference paths.
        if let root = projectRoot {
            for i in skills.indices {
                let links = linkPaths[skills[i].canonicalPath] ?? []
                let locs = Set(links.map { location(ofEntry: $0, underRoot: root) })
                skills[i].projectLocations = locs.sorted()
            }
        }

        for i in skills.indices {
            let canon = skills[i].canonicalPath
            let status = git[canon] ?? .notInRepo
            skills[i].gitStatus = status
            if let links = linkPaths[canon] {
                skills[i].linksDiverge = links.contains { (git[$0] ?? status) != status }
            }
            // Diverged = a *genuine* clash: another skill with the same name that shares a
            // location. Same name in different monorepo subpackages is expected, not drift.
            // In global scope every skill's location set is {""}, so this reduces to the
            // original "same name across ≥2 canonical paths" rule.
            let myLocs = locationKeys(skills[i])
            skills[i].diverged = skills.contains { other in
                other.canonicalPath != canon
                    && other.name == skills[i].name
                    && !locationKeys(other).isDisjoint(with: myLocs)
            }
        }

        return skills.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Location keys for divergence comparison; empty (global) collapses to a single
    /// shared "" bucket so global same-name skills still count as diverged.
    private static func locationKeys(_ s: Skill) -> Set<String> {
        s.projectLocations.isEmpty ? [""] : Set(s.projectLocations)
    }

    /// Project-relative subpackage of a skill reference path `<base>/.X/skills/<name>`.
    /// "" = the chosen root; "↑ <dir>" = an ancestor above it.
    private static func location(ofEntry entry: String, underRoot root: String) -> String {
        var base = URL(fileURLWithPath: entry)
        for _ in 0..<3 { base = base.deletingLastPathComponent() } // drop <name>/skills/.X
        let bp = base.standardizedFileURL.path
        let rp = URL(fileURLWithPath: root).standardizedFileURL.path
        if bp == rp { return "" }
        if bp.hasPrefix(rp + "/") { return String(bp.dropFirst(rp.count + 1)) }
        return "↑ " + base.lastPathComponent
    }

    // MARK: - Base discovery

    /// Bases to probe for agent skill dirs: ancestors (chosen dir → git root) plus
    /// descendants up to `maxDescentDepth` levels (monorepos nest .claude/.agents in
    /// subpackages). Deduped by standardized path, preserving discovery order.
    static func projectBases(from root: URL) -> [URL] {
        var bases = ancestorRoots(from: root)
        bases.append(contentsOf: descendantRoots(from: root))
        var seen = Set<String>()
        return bases.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Every agent skill dir the project scan looks at, for the FileWatcher. Covers the
    /// same ancestor+descendant bases `scanProject` scans — so edits to a nested package's
    /// `.claude/skills` fire a reload, not just the chosen root's. FileWatcher filters out
    /// paths that don't exist, so we needn't stat here.
    static func projectSkillDirPaths(from root: URL) -> [String] {
        projectBases(from: root).flatMap { base in
            Agent.allCases.flatMap { agent in
                agent.projectSkillDirs.map { base.appendingPathComponent($0).path }
            }
        }
    }

    // MARK: - Helpers

    /// How many directory levels below the chosen root we look for nested agent dirs.
    /// Depth 1 = `root/<pkg>/.claude/skills`, depth 3 = `root/a/b/c/.claude/skills`.
    private static let maxDescentDepth = 3

    /// Dirs we never traverse into — VCS, build output, and dependency trees that would
    /// blow up the walk (and whose vendored skills aren't "the project's" anyway).
    private static let pruneDirNames: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "out", ".next", ".nuxt",
        "target", "vendor", "Pods", ".venv", "venv", "__pycache__", ".turbo",
        "DerivedData", ".gradle", ".cache", "Carthage"
    ]

    /// Breadth-first walk from `root` (exclusive) down to `maxDescentDepth` levels,
    /// returning every subdirectory that could host an agent skills dir. Skips hidden
    /// dirs (incl. the agent dirs themselves — we probe those by name at each base),
    /// symlinks (cycle-safe), and pruned build/dependency dirs.
    private static func descendantRoots(from root: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var result: [URL] = []
        var frontier: [(dir: URL, depth: Int)] = [(root.standardizedFileURL, 0)]

        while !frontier.isEmpty {
            let (dir, depth) = frontier.removeFirst()
            if depth >= maxDescentDepth { continue }
            guard let children = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                let vals = try? child.resourceValues(forKeys: Set(keys))
                guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }
                if pruneDirNames.contains(child.lastPathComponent) { continue }
                result.append(child)
                frontier.append((child, depth + 1))
            }
        }
        return result
    }

    /// Walk from `start` up to (and including) the git repo root; if not in a repo,
    /// just return `start`. Used so project skills in ancestor dirs are discovered.
    private static func ancestorRoots(from start: URL) -> [URL] {
        let top = gitTopLevel(for: start)
        var dirs: [URL] = []
        var cur = start.standardizedFileURL
        while true {
            dirs.append(cur)
            if let top, cur.path == top.path { break }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break } // filesystem root
            if top == nil { break } // not in a repo → only scan start
            cur = parent
        }
        return dirs
    }

    private static func gitTopLevel(for dir: URL) -> URL? {
        guard let git = GitStatusService.gitPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", dir.path, "rev-parse", "--show-toplevel"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : URL(fileURLWithPath: s)
    }

    /// Top-level entries packaged with a skill (excluding SKILL.md), dirs-first then by
    /// name. One `contentsOfDirectory` per unique skill — a cheap FS read, no subprocess.
    private static func bundledFiles(in canonical: URL, fm: FileManager) -> [BundledFile] {
        guard let entries = try? fm.contentsOfDirectory(
            at: canonical, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.lastPathComponent != "SKILL.md" }
            .map { BundledFile(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private static func declaredByPath(_ items: [CLISkill]) -> [String: Set<Agent>] {
        var out: [String: Set<Agent>] = [:]
        for item in items {
            let p = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
            out[p, default: []].formUnion(item.agents.compactMap(Agent.from(cliDisplayName:)))
        }
        return out
    }
}
