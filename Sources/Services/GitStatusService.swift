import Foundation

/// Classifies directory paths by git-tracked status, batched per enclosing repo.
/// Distinguishes tracked / untracked / ignored / not-in-repo with correct exit-code
/// handling (a sibling concern flagged by review: `check-ignore` exits 1 for "not
/// ignored", 128 for error — never conflate). All work is synchronous; callers run
/// it off the main actor.
///
/// Cost: one `rev-parse` per distinct parent dir (memoized), then exactly ONE
/// `ls-files` and ONE `check-ignore` per repo root — not 2-3 spawns per path. A
/// project with N skill dirs costs ~repos×2 + parents git invocations instead of ~3N.
enum GitStatusService {
    static func isAvailable(_ io: HostIO) -> Bool { gitPath(io) != nil }

    static func gitPath(_ io: HostIO) -> String? {
        for p in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where io.exists(p) { return p }
        return nil
    }

    /// Returns a status for every input path. Paths in the same repo share repo-root
    /// lookups and are classified together in two batched git calls.
    static func classify(paths: [String], io: HostIO) -> [String: GitStatus] {
        guard gitPath(io) != nil else { return [:] }
        var result: [String: GitStatus] = [:]

        // 1. Resolve each path's repo root via its PARENT context (so the path itself
        //    being a symlink/nested-repo entry doesn't classify from a child repo).
        //    Memoized per parent dir. No repo → notInRepo, recorded now.
        var repoCache: [String: String?] = [:]
        func repoRoot(forParent dir: String) -> String? {
            if let cached = repoCache[dir] { return cached }
            let r = run(["-C", dir, "rev-parse", "--show-toplevel"], io: io)
            let root: String? = (r.code == 0)
                ? r.out.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                : nil
            repoCache[dir] = root
            return root
        }

        var byRepo: [String: [String]] = [:] // repoRoot -> [absolute paths]
        for path in Set(paths) {
            if let root = repoRoot(forParent: parentDir(path)) {
                byRepo[root, default: []].append(path)
            } else {
                result[path] = .notInRepo
            }
        }

        for (root, group) in byRepo {
            // Repo-relative paths (normalized, no trailing slash), with a reverse map.
            var rels: [String] = []
            var relToAbs: [String: String] = [:]
            for abs in group {
                let rel = relative(abs, to: root, io: io)
                // If the path didn't reduce to repo-relative (symlink resolution escaped the
                // root), don't hand git an absolute pathspec it can't match — report honestly.
                if rel.hasPrefix("/") { result[abs] = .notInRepo; continue }
                rels.append(rel)
                relToAbs[rel] = abs
            }

            // 2. Tracked? ONE ls-files over all pathspecs. A queried dir is tracked if any
            //    listed entry equals it OR sits beneath it (exact-or-prefix — `ls-files --
            //    dir` emits descendants, so equality alone would miss tracked directories).
            //    `--literal-pathspecs` so names with pathspec magic aren't reinterpreted.
            //    ls-files exits 0 even when nothing matches → empty output means "none".
            let ls = run(["-C", root, "--literal-pathspecs", "ls-files", "-z", "--"] + rels, io: io)
            let listed = ls.out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            var trackedRels = Set<String>()
            if !listed.isEmpty {
                for rel in rels where listed.contains(where: { $0 == rel || $0.hasPrefix(rel + "/") }) {
                    trackedRels.insert(rel)
                }
            }

            // 3. Ignored? ONE check-ignore over the not-yet-tracked paths (via stdin, NUL-
            //    delimited, so arbitrary counts and odd names are safe). For real dirs we
            //    also query "<rel>/" to catch directory-only ignore rules (`foo/`); for
            //    symlink entries we query only the bare pathname (never the target dir).
            //    `--no-index` consults ignore rules irrespective of the index; tracked
            //    precedence already applied above. Exit 0 = some ignored (parse stdout),
            //    1 = none, 128 = fatal (fall back to per-path for exactness).
            let notTracked = rels.filter { !trackedRels.contains($0) }
            var ignoredRels = Set<String>()
            if !notTracked.isEmpty {
                var queryToRel: [String: String] = [:]
                for rel in notTracked {
                    queryToRel[rel] = rel
                    if isRealDirectory(relToAbs[rel]!, io: io) { queryToRel[rel + "/"] = rel }
                }
                let queries = Array(queryToRel.keys)
                let stdin = (queries.joined(separator: "\0") + "\0").data(using: .utf8)
                let ci = run(["-C", root, "check-ignore", "--stdin", "--no-index", "-z"], io: io, stdin: stdin)
                if ci.code == 0 {
                    for hit in ci.out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) {
                        if let rel = queryToRel[hit] { ignoredRels.insert(rel) }
                    }
                } else if ci.code == 128 {
                    for rel in notTracked where run(["-C", root, "check-ignore", "-q", rel], io: io).code == 0 {
                        ignoredRels.insert(rel)
                    }
                }
            }

            // 4. Resolve precedence: tracked > ignored > untracked.
            for rel in rels {
                let abs = relToAbs[rel]!
                if trackedRels.contains(rel) { result[abs] = .tracked }
                else if ignoredRels.contains(rel) { result[abs] = .ignored }
                else { result[abs] = .untracked }
            }
        }
        return result
    }

    private static func isRealDirectory(_ path: String, io: HostIO) -> Bool {
        // lstat semantics: a symlink-to-dir is NOT a real dir. listDir reports the entry's
        // OWN type (isSymlink from lstat, isDir following), so a real dir is dir && !symlink.
        // Only real dirs get the "/" query.
        let parent = parentDir(path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard let entries = try? io.listDir(parent),
              let entry = entries.first(where: { $0.name == name })
        else { return false }
        return entry.isDir && !entry.isSymlink
    }

    private static func parentDir(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func relative(_ path: String, to root: String, io: HostIO) -> String {
        // `rev-parse --show-toplevel` returns the realpath, so resolve symlinks in the
        // PARENT to match it (e.g. /tmp → /private/tmp, or a project under a symlinked
        // dir) — otherwise the prefix strip below fails and we'd hand git an absolute
        // pathspec. Keep the final component unresolved: a symlinked skill entry is
        // tracked/ignored at its OWN pathname, not its target's.
        let url = URL(fileURLWithPath: path)
        let resolved = URL(fileURLWithPath: io.realpath(url.deletingLastPathComponent().path))
            .appendingPathComponent(url.lastPathComponent).path
        if resolved == root { return "." }
        if resolved.hasPrefix(root + "/") { return String(resolved.dropFirst(root.count + 1)) }
        return resolved
    }

    @discardableResult
    private static func run(_ args: [String], io: HostIO, stdin: Data? = nil) -> (out: String, code: Int32) {
        guard let git = gitPath(io) else { return ("", -1) }
        let r = io.run([git] + args, cwd: nil, stdin: stdin)
        return (String(data: r.stdout, encoding: .utf8) ?? "", r.exit)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
