import Foundation

/// One entry from `skills list --json`.
struct CLISkill: Decodable {
    let name: String
    let path: String
    let scope: String
    let agents: [String]
}

/// Bridge to the skills.sh `skills` CLI.
///
/// GUI apps don't inherit the user's shell PATH, so we locate the binary at known
/// install locations rather than relying on `npx` (which can be slow / networked /
/// a different version). All mutations should route through this service.
enum SkillsCLIService {
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/skills",
            "/usr/local/bin/skills",
            "\(home)/.local/bin/skills",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var isAvailable: Bool { locate() != nil }

    /// `skills list -g --json` — global skills with their declared agent targets.
    static func listGlobalJSON() -> [CLISkill] {
        run(arguments: ["list", "-g", "--json"])
    }

    /// `skills list --json` run in `directory` — project-scoped skills.
    static func listProjectJSON(in directory: URL) -> [CLISkill] {
        run(arguments: ["list", "--json"], cwd: directory)
    }

    private static func run(arguments: [String], cwd: URL? = nil) -> [CLISkill] {
        guard let bin = locate() else { return [] }
        let process = Process()
        process.executableURL = bin
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return (try? JSONDecoder().decode([CLISkill].self, from: data)) ?? []
    }
}
