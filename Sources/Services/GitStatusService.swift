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
    static var isAvailable: Bool { gitPath != nil }

    static let gitPath: String? = {
        for p in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    /// Returns a status for every input path. Paths in the same repo share repo-root
    /// lookups and are classified together in two batched git calls.
    static func classify(paths: [String]) -> [String: GitStatus] {
        guard gitPath != nil else { return [:] }
        var result: [String: GitStatus] = [:]

        // 1. Resolve each path's repo root via its PARENT context (so the path itself
        //    being a symlink/nested-repo entry doesn't classify from a child repo).
        //    Memoized per parent dir. No repo → notInRepo, recorded now.
        var repoCache: [String: String?] = [:]
        func repoRoot(forParent dir: String) -> String? {
            if let cached = repoCache[dir] { return cached }
            let r = run(["-C", dir, "rev-parse", "--show-toplevel"])
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

        let fm = FileManager.default
        for (root, group) in byRepo {
            // Repo-relative paths (normalized, no trailing slash), with a reverse map.
            var rels: [String] = []
            var relToAbs: [String: String] = [:]
            for abs in group {
                let rel = relative(abs, to: root)
                rels.append(rel)
                relToAbs[rel] = abs
            }

            // 2. Tracked? ONE ls-files over all pathspecs. A queried dir is tracked if any
            //    listed entry equals it OR sits beneath it (exact-or-prefix — `ls-files --
            //    dir` emits descendants, so equality alone would miss tracked directories).
            //    `--literal-pathspecs` so names with pathspec magic aren't reinterpreted.
            //    ls-files exits 0 even when nothing matches → empty output means "none".
            let ls = run(["-C", root, "--literal-pathspecs", "ls-files", "-z", "--"] + rels)
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
                    if isRealDirectory(relToAbs[rel]!, fm: fm) { queryToRel[rel + "/"] = rel }
                }
                let queries = Array(queryToRel.keys)
                let stdin = (queries.joined(separator: "\0") + "\0").data(using: .utf8)
                let ci = run(["-C", root, "check-ignore", "--stdin", "--no-index", "-z"], stdin: stdin)
                if ci.code == 0 {
                    for hit in ci.out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) {
                        if let rel = queryToRel[hit] { ignoredRels.insert(rel) }
                    }
                } else if ci.code == 128 {
                    for rel in notTracked where run(["-C", root, "check-ignore", "-q", rel]).code == 0 {
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

    private static func isRealDirectory(_ path: String, fm: FileManager) -> Bool {
        // lstat semantics: attributesOfItem does not follow links, so a symlink-to-dir
        // reports .typeSymbolicLink, not .typeDirectory. Only real dirs get the "/" query.
        let attrs = try? fm.attributesOfItem(atPath: path)
        return (attrs?[.type] as? FileAttributeType) == .typeDirectory
    }

    private static func parentDir(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func relative(_ path: String, to root: String) -> String {
        // `rev-parse --show-toplevel` returns the realpath, so resolve symlinks in the
        // PARENT to match it (e.g. /tmp → /private/tmp, or a project under a symlinked
        // dir) — otherwise the prefix strip below fails and we'd hand git an absolute
        // pathspec. Keep the final component unresolved: a symlinked skill entry is
        // tracked/ignored at its OWN pathname, not its target's.
        let url = URL(fileURLWithPath: path)
        let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
        if resolved == root { return "." }
        if resolved.hasPrefix(root + "/") { return String(resolved.dropFirst(root.count + 1)) }
        return resolved
    }

    @discardableResult
    private static func run(_ args: [String], stdin: Data? = nil) -> (out: String, code: Int32) {
        guard let git = gitPath else { return ("", -1) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        let inPipe: Pipe?
        if stdin != nil { inPipe = Pipe(); p.standardInput = inPipe } else { inPipe = nil }

        do { try p.run() } catch { return ("", -1) }

        // Feed stdin on a background queue and close it, so a large input can't deadlock
        // against us reading stdout (writer fills its buffer, we fill ours, both block).
        if let inPipe, let stdin {
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
