import Foundation

/// A config file that existed but couldn't be parsed — surfaced to the user so MCP state
/// for that harness is honestly reported as "unknown" rather than silently dropped.
struct McpConfigIssue: Hashable, Identifiable {
    let harness: McpHarness
    let label: String
    let path: String
    let reason: String
    var id: String { "\(path)" }
}

struct McpScanResult: Equatable {
    var servers: [McpServer]
    var issues: [McpConfigIssue]
    static let empty = McpScanResult(servers: [], issues: [])
}

/// Discovers MCP servers by PARSING each harness's config (not scanning dirs — the key
/// difference from skills, DECISIONS D3). Servers collapse across harnesses by identity
/// (`scope + logicalLocation + name`) into `[McpServer]`, each carrying the four
/// cross-harness states. Mirrors `SkillScanner`'s shape; reuses its project-base discovery
/// (ancestors + monorepo descendants) and `GitStatusService` for config-file git status.
enum McpScanner {
    static func scanGlobal() -> McpScanResult {
        var feeds: [Feed] = []
        for h in McpHarness.allCases {
            feeds.append(Feed(logicalLocation: "", harness: h,
                              locations: McpConfigDescriptor.globalLocations(h)))
        }
        return collapse(feeds, scope: .global)
    }

    static func scanProject(root: URL) -> McpScanResult {
        var feeds: [Feed] = []
        for base in SkillScanner.projectBases(from: root) {
            let logical = locationLabel(base: base, root: root)
            for h in McpHarness.allCases {
                feeds.append(Feed(logicalLocation: logical, harness: h,
                                  locations: McpConfigDescriptor.projectLocations(h, base: base)))
            }
        }
        return collapse(feeds, scope: .project(root: root.path))
    }

    /// Paths to hand the FileWatcher. FSEvents watches a directory RECURSIVELY, so we must
    /// never hand it the home directory or a project root — both churn constantly (and
    /// `~/.claude.json` in particular is rewritten by Claude Code itself many times a
    /// minute), which would put the MCP view into an endless reload loop.
    ///
    /// Rule: watch a config file's PARENT only when that parent is a dedicated config dir
    /// (`.codex`, `.cursor`, `.config/opencode`); when the parent is home or a project root,
    /// watch the file itself instead — except `~/.claude.json`, which is too high-churn to
    /// watch at all (its MCP edits are picked up on the next manual refresh).
    static func configWatchPaths(global: Bool, root: URL?) -> [String] {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let claudeUserFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json").standardizedFileURL.path
        var excludedDirs: Set<String> = [homePath]

        var locations: [McpConfigLocation] = []
        if global {
            for h in McpHarness.allCases { locations += McpConfigDescriptor.globalLocations(h) }
        } else if let root {
            for base in SkillScanner.projectBases(from: root) {
                excludedDirs.insert(base.standardizedFileURL.path)
                for h in McpHarness.allCases { locations += McpConfigDescriptor.projectLocations(h, base: base) }
            }
        }

        var paths = Set<String>()
        for l in locations {
            let parent = l.url.deletingLastPathComponent().standardizedFileURL.path
            if excludedDirs.contains(parent) {
                // Parent too broad to watch recursively — watch the file directly, unless
                // it's the constantly-rewritten Claude user config.
                if l.url.standardizedFileURL.path != claudeUserFile { paths.insert(l.url.path) }
            } else {
                paths.insert(parent)
            }
        }
        return Array(paths)
    }

    // MARK: - Core

    private struct Feed {
        let logicalLocation: String
        let harness: McpHarness
        let locations: [McpConfigLocation]
    }

    private struct Key: Hashable { let logicalLocation: String; let name: String }

    private struct Acc {
        var entries: [McpHarness: AgentMcpEntry] = [:]
        var origins: [McpHarness: [McpConfigLocation]] = [:]
        var conflicted: Set<McpHarness> = []
        var primaryPath: [McpHarness: String] = [:]   // file path of the primary origin
    }

    private static func collapse(_ feeds: [Feed], scope: ResourceScope) -> McpScanResult {
        var byKey: [Key: Acc] = [:]
        var issues: [McpConfigIssue] = []

        for feed in feeds {
            // Primary location ordered first → first write wins, later origins only annotate.
            for loc in feed.locations {
                switch McpConfigCodec.read(loc) {
                case .absent:
                    continue
                case .malformed(let reason):
                    issues.append(McpConfigIssue(harness: feed.harness, label: loc.label,
                                                 path: loc.url.path, reason: reason))
                case .ok(let entriesByName):
                    for (name, entry) in entriesByName {
                        let key = Key(logicalLocation: feed.logicalLocation, name: name)
                        var acc = byKey[key] ?? Acc()
                        if let existing = acc.entries[feed.harness] {
                            // A second origin for the same harness — keep the primary, but
                            // flag a conflict if the definitions genuinely disagree.
                            if existing.portable?.signature != entry.portable?.signature {
                                acc.conflicted.insert(feed.harness)
                            }
                            acc.origins[feed.harness, default: []].append(loc)
                        } else {
                            acc.entries[feed.harness] = entry
                            acc.origins[feed.harness] = [loc]
                            acc.primaryPath[feed.harness] = loc.url.path
                        }
                        byKey[key] = acc
                    }
                }
            }
        }

        // Git status: classify every primary config-file path in one batch.
        let allPaths = byKey.values.flatMap { Array($0.primaryPath.values) }
        let git = GitStatusService.classify(paths: Array(Set(allPaths)))

        var servers: [McpServer] = []
        for (key, acc) in byKey {
            var gitByHarness: [McpHarness: GitStatus] = [:]
            for (h, path) in acc.primaryPath { gitByHarness[h] = git[path] ?? .notInRepo }
            servers.append(McpServer(
                name: key.name,
                scope: scope,
                logicalLocation: key.logicalLocation,
                entries: acc.entries,
                origins: acc.origins,
                gitStatusByHarness: gitByHarness,
                conflictedHarnesses: acc.conflicted))
        }

        servers.sort {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.logicalLocation < $1.logicalLocation
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return McpScanResult(servers: servers, issues: issues.sorted { $0.path < $1.path })
    }

    /// Project-relative label for a config base dir: "" = chosen root, "↑ <dir>" = an
    /// ancestor above it, otherwise the path relative to the root (a monorepo subpackage).
    private static func locationLabel(base: URL, root: URL) -> String {
        let bp = base.standardizedFileURL.path
        let rp = root.standardizedFileURL.path
        if bp == rp { return "" }
        if bp.hasPrefix(rp + "/") { return String(bp.dropFirst(rp.count + 1)) }
        return "↑ " + base.lastPathComponent
    }
}
