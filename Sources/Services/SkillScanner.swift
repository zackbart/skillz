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
        for base in ancestorRoots(from: root) {
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
                    at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }

                for entry in entries {
                    let skillMd = entry.appendingPathComponent("SKILL.md")
                    guard fm.fileExists(atPath: skillMd.path) else { continue }

                    let canonical = entry.resolvingSymlinksInPath()
                    let key = canonical.path
                    linkPaths[key, default: []].insert(entry.path)

                    if byCanonical[key] != nil {
                        byCanonical[key]?.wiredAgents.insert(agent)
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
                    skill.declaredAgents = declared[key] ?? []
                    byCanonical[key] = skill
                }
            }
        }

        return finalize(byCanonical, linkPaths: linkPaths)
    }

    private static func finalize(
        _ byCanonical: [String: Skill],
        linkPaths: [String: Set<String>]
    ) -> [Skill] {
        var skills = Array(byCanonical.values)

        // Git status — classify canonical dirs + their (unresolved) link paths in one batch.
        var allPaths = Set(byCanonical.keys)
        for (_, links) in linkPaths { allPaths.formUnion(links) }
        let git = GitStatusService.classify(paths: Array(allPaths))

        // Diverged — same name across ≥2 distinct canonical paths in this scope.
        var nameCounts: [String: Int] = [:]
        for s in skills { nameCounts[s.name, default: 0] += 1 }

        for i in skills.indices {
            let canon = skills[i].canonicalPath
            let status = git[canon] ?? .notInRepo
            skills[i].gitStatus = status
            if let links = linkPaths[canon] {
                skills[i].linksDiverge = links.contains { (git[$0] ?? status) != status }
            }
            skills[i].diverged = (nameCounts[skills[i].name] ?? 0) > 1
        }

        return skills.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Helpers

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

    private static func declaredByPath(_ items: [CLISkill]) -> [String: Set<Agent>] {
        var out: [String: Set<Agent>] = [:]
        for item in items {
            let p = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
            out[p, default: []].formUnion(item.agents.compactMap(Agent.from(cliDisplayName:)))
        }
        return out
    }
}
