import Foundation

/// Classifies directory paths by git-tracked status, batched per enclosing repo.
/// Distinguishes tracked / untracked / ignored / not-in-repo with correct exit-code
/// handling (a sibling concern flagged by review: `check-ignore` exits 1 for "not
/// ignored", 128 for error — never conflate). All work is synchronous; callers run
/// it off the main actor.
enum GitStatusService {
    static var isAvailable: Bool { gitPath != nil }

    static let gitPath: String? = {
        for p in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    /// Returns a status for every input path. Paths in the same repo share repo-root lookups.
    static func classify(paths: [String]) -> [String: GitStatus] {
        guard gitPath != nil else { return [:] }
        var result: [String: GitStatus] = [:]
        var repoCache: [String: String?] = [:]

        func repoRoot(for dir: String) -> String? {
            if let cached = repoCache[dir] { return cached }
            let r = run(["-C", dir, "rev-parse", "--show-toplevel"])
            let root: String? = (r.code == 0)
                ? r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            repoCache[dir] = root
            return root
        }

        for path in Set(paths) {
            // The path may itself be a symlink; resolve its *parent context* via -C.
            guard let root = repoRoot(for: parentDir(path)) else {
                result[path] = .notInRepo
                continue
            }
            let rel = relative(path, to: root)

            // Tracked? ls-files lists committed/staged entries under the path.
            if !run(["-C", root, "ls-files", "--", rel]).out
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[path] = .tracked
                continue
            }
            // Ignored? check-ignore -q exits 0 when ignored, 1 when not, 128 on error.
            if run(["-C", root, "check-ignore", "-q", rel]).code == 0 {
                result[path] = .ignored
                continue
            }
            result[path] = .untracked
        }
        return result
    }

    private static func parentDir(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().path
    }

    private static func relative(_ path: String, to root: String) -> String {
        if path == root { return "." }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }

    @discardableResult
    private static func run(_ args: [String]) -> (out: String, code: Int32) {
        guard let git = gitPath else { return ("", -1) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return ("", -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}
