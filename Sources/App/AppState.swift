import SwiftUI
import AppKit

enum ScopeMode: String, CaseIterable, Hashable {
    case global, project
    var label: String { self == .global ? "Global" : "Project" }
}

enum LibraryFilter: String, CaseIterable, Hashable {
    case all, drift, diverged
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

@MainActor
final class AppState: ObservableObject {
    // Navigation / filters
    @Published var kind: ResourceKind = .skill
    @Published var scopeMode: ScopeMode = .global
    @Published var selectedProject: URL?
    @Published var recentProjects: [URL] = []
    @Published var libraryFilter: LibraryFilter = .all
    @Published var selectedAgent: Agent?
    @Published var selectedSource: String?

    // Data
    @Published var skills: [Skill] = []
    @Published var selection: Skill.ID?
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var cliAvailable = false
    @Published var gitAvailable = false

    private var watcher: FileWatcher?
    private let recentsKey = "recentProjects"

    init() {
        recentProjects = (UserDefaults.standard.array(forKey: recentsKey) as? [String])?
            .map { URL(fileURLWithPath: $0) } ?? []
        watcher = FileWatcher { [weak self] in self?.reload() }
    }

    // MARK: - Derived

    var driftCount: Int { skills.filter { !$0.driftMissing.isEmpty }.count }
    var divergedCount: Int { skills.filter { $0.diverged }.count }

    func count(for agent: Agent) -> Int {
        skills.filter { $0.availableAgents.contains(agent) }.count
    }

    var sources: [(name: String, count: Int)] {
        var m: [String: Int] = [:]
        for s in skills {
            if let src = s.provenance?.source, !src.isEmpty { m[src, default: 0] += 1 }
        }
        return m.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var filteredSkills: [Skill] {
        var list = skills
        switch libraryFilter {
        case .all: break
        case .drift: list = list.filter { !$0.driftMissing.isEmpty }
        case .diverged: list = list.filter { $0.diverged }
        }
        if let agent = selectedAgent {
            list = list.filter { $0.availableAgents.contains(agent) || $0.declaredAgents.contains(agent) }
        }
        if let src = selectedSource {
            list = list.filter { $0.provenance?.source == src }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q)
                    || ($0.summary?.lowercased().contains(q) ?? false)
                    || $0.bodyMarkdown.lowercased().contains(q)
            }
        }
        return list
    }

    var selectedSkill: Skill? {
        guard let selection else { return nil }
        return skills.first { $0.id == selection }
    }

    // MARK: - Project selection

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        if panel.runModal() == .OK, let url = panel.url {
            setProject(url)
        } else if selectedProject == nil {
            scopeMode = .global // cancelled with no project chosen → don't strand in empty Project scope
            reload()
        }
    }

    func setProject(_ url: URL) {
        selectedProject = url
        scopeMode = .project
        recentProjects.removeAll { $0.path == url.path }
        recentProjects.insert(url, at: 0)
        recentProjects = Array(recentProjects.prefix(8))
        UserDefaults.standard.set(recentProjects.map(\.path), forKey: recentsKey)
        reload()
    }

    // MARK: - Loading

    func reload() {
        isLoading = true
        let mode = scopeMode
        let project = selectedProject
        Task.detached(priority: .userInitiated) {
            let scanned: [Skill]
            switch mode {
            case .global: scanned = SkillScanner.scanGlobal()
            case .project: scanned = project.map { SkillScanner.scanProject(root: $0) } ?? []
            }
            let cli = SkillsCLIService.isAvailable
            let git = GitStatusService.isAvailable
            await MainActor.run {
                self.skills = scanned
                self.cliAvailable = cli
                self.gitAvailable = git
                self.isLoading = false
                if let sel = self.selection, !scanned.contains(where: { $0.id == sel }) {
                    self.selection = nil
                }
                if let src = self.selectedSource, !self.sources.contains(where: { $0.name == src }) {
                    self.selectedSource = nil
                }
                self.updateWatcher()
            }
        }
    }

    private func updateWatcher() {
        // Always watch the global/canonical dirs so edits to a symlinked skill's real
        // files (under ~/.agents/skills) fire a reload regardless of scope.
        var paths = Agent.allCases.flatMap { $0.globalSkillDirs.map(\.path) }
        if scopeMode == .project, let root = selectedProject {
            for agent in Agent.allCases {
                for rel in agent.projectSkillDirs {
                    paths.append(root.appendingPathComponent(rel).path)
                }
            }
        }
        watcher?.start(paths: paths)
    }

    // MARK: - Mutations

    /// Wire a skill into an agent by creating the missing symlink to its canonical dir,
    /// mirroring `npx skills`: write the canonical files to `.agents/skills`, then a
    /// RELATIVE symlink (e.g. `../../.agents/skills/<name>`) in the agent's own dir.
    /// Only non-universal agents (Claude Code) ever need this; reversible.
    func wire(_ skill: Skill, into agent: Agent) {
        let dir: URL
        if skill.scope.isGlobal {
            guard let g = agent.globalSkillDirs.first else { return }
            dir = g
        } else if let root = skill.scope.projectRoot, let rel = agent.projectSkillDirs.first {
            dir = URL(fileURLWithPath: root).appendingPathComponent(rel)
        } else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent(skill.name)
        let relTarget = Self.relativePath(from: dir.path, to: skill.canonicalPath)
        try? fm.removeItem(at: link) // clear a stale/broken link if present
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: relTarget)
        reload()
    }

    /// Relative path from a directory to a target (so symlinks stay portable, like the CLI's).
    private static func relativePath(from base: String, to target: String) -> String {
        let b = base.split(separator: "/").map(String.init)
        let t = target.split(separator: "/").map(String.init)
        var i = 0
        while i < b.count, i < t.count, b[i] == t[i] { i += 1 }
        let up = Array(repeating: "..", count: b.count - i)
        return (up + t[i...]).joined(separator: "/")
    }

    func openInEditor(_ skill: Skill) {
        NSWorkspace.shared.open(skill.skillMdURL)
    }
}
