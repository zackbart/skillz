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

/// Identifies which mutation a status refers to, so per-row UI reacts only to its OWN
/// action (one global `actionStatus` would otherwise light up every wire button at once,
/// and let a background reload dismiss the install sheet).
enum ActionID: Equatable {
    case install
    case fixAllDrift
    case wire(Skill.ID, Agent)
    case update(Skill.ID)
    case remove(Skill.ID)
}

/// Status of an in-flight mutation — drives spinners, inline confirmations and the alert.
/// Each case carries the `ActionID` it belongs to.
enum ActionStatus: Equatable {
    case idle
    case running(ActionID, String)
    case success(ActionID, String)
    case failure(ActionID, String)

    /// Any mutation in flight — used for single-flight disabling across the whole UI.
    var isRunning: Bool { if case .running = self { return true }; return false }

    /// Is THIS specific action the one currently running? (scopes spinners to one button)
    func isRunning(_ id: ActionID) -> Bool {
        if case .running(let a, _) = self { return a == id }
        return false
    }

    /// The running label, but only for the given action.
    func runningLabel(_ id: ActionID) -> String? {
        if case .running(let a, let label) = self, a == id { return label }
        return nil
    }

    /// The failure message, but only for the given action.
    func failureMessage(_ id: ActionID) -> String? {
        if case .failure(let a, let msg) = self, a == id { return msg }
        return nil
    }

    /// Did the given action just succeed? (used by the install sheet to self-dismiss)
    func didSucceed(_ id: ActionID) -> Bool {
        if case .success(let a, _) = self { return a == id }
        return false
    }
}

/// The one active sidebar filter. Single-selection like a native macOS sidebar:
/// choosing one clears the others. `.library(.all)` is the unfiltered default.
enum SidebarFilter: Hashable {
    case library(LibraryFilter)
    case agent(Agent)
    case source(String)
}

@MainActor
final class AppState: ObservableObject {
    // Navigation / filters
    @Published var kind: ResourceKind = .skill
    @Published var scopeMode: ScopeMode = .global { didSet { persistScope() } }
    @Published var selectedProject: URL?
    /// Projects the user has saved — persisted indefinitely, switchable, removable.
    @Published var savedProjects: [URL] = []
    // Single-select sidebar filter (native macOS list selection). Reconciles the skill
    // selection on change so the detail pane never shows a filtered-out skill.
    @Published var sidebarFilter: SidebarFilter = .library(.all) { didSet { reconcileSelection() } }

    // Data
    @Published var skills: [Skill] = []
    @Published var selection: Skill.ID?
    @Published var searchText = "" { didSet { reconcileSelection() } }
    @Published var isLoading = false
    @Published var cliAvailable = false
    @Published var gitAvailable = false

    // Mutation surface
    @Published var actionStatus: ActionStatus = .idle   // drives spinners / inline confirmations
    @Published var lastError: String?                   // alert binding (non-nil ⇒ show alert)
    @Published var pendingSelectName: String?           // name to select once it appears post-reload

    private var watcher: FileWatcher?
    private let projectsKey = "recentProjects" // key kept for continuity with existing data
    private let activeProjectKey = "activeProject"
    private let scopeKey = "scopeMode"
    /// Bumped on every reload; a detached scan only applies if it's still the latest.
    private var reloadGeneration = 0

    init() {
        savedProjects = (UserDefaults.standard.array(forKey: projectsKey) as? [String])?
            .map { URL(fileURLWithPath: $0) } ?? []
        // Remember the last active project so switching to the Project tab is instant
        // (only restore it if it's still a saved project).
        if let path = UserDefaults.standard.string(forKey: activeProjectKey),
           savedProjects.contains(where: { $0.path == path }) {
            selectedProject = URL(fileURLWithPath: path)
        } else {
            selectedProject = savedProjects.first
        }
        // Resume the last scope — but never strand in Project scope with no project.
        if let raw = UserDefaults.standard.string(forKey: scopeKey),
           let saved = ScopeMode(rawValue: raw) {
            scopeMode = saved
        }
        if scopeMode == .project && selectedProject == nil { scopeMode = .global }
        watcher = FileWatcher { [weak self] in self?.reload() }
    }

    // MARK: - Derived

    var driftCount: Int { skills.filter { !$0.driftMissing.isEmpty }.count }
    var divergedCount: Int { skills.filter { $0.diverged }.count }

    /// Badge count — must use the SAME predicate as `filteredSkills`' agent clause
    /// (available OR declared) so the sidebar number matches the produced list.
    func count(for agent: Agent) -> Int {
        skills.filter { $0.availableAgents.contains(agent) || $0.declaredAgents.contains(agent) }.count
    }

    /// UI scope → the `ResourceScope` the CLI wrappers expect.
    var currentScope: ResourceScope {
        if scopeMode == .project, let root = selectedProject { return .project(root: root.path) }
        return .global
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
        switch sidebarFilter {
        case .library(.all): break
        case .library(.drift): list = list.filter { !$0.driftMissing.isEmpty }
        case .library(.diverged): list = list.filter { $0.diverged }
        case .agent(let agent):
            list = list.filter { $0.availableAgents.contains(agent) || $0.declaredAgents.contains(agent) }
        case .source(let src):
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

    /// Resolve against the VISIBLE list so the detail pane never shows a filtered-out skill.
    var selectedSkill: Skill? {
        guard let selection else { return nil }
        return filteredSkills.first { $0.id == selection }
    }

    // MARK: - Selection / filter coherence

    /// Clear the selection if it's no longer in the visible list (called from filter didSets).
    func reconcileSelection() {
        if let sel = selection, !filteredSkills.contains(where: { $0.id == sel }) {
            selection = nil
        }
    }

    /// Reset all filters + selection. Called on scope/project change so carried-over
    /// agent/source/lib/search state can't silently empty the list. Selection is set last
    /// so the net result is always `selection == nil` regardless of didSet ordering.
    func resetFilters() {
        sidebarFilter = .library(.all)
        searchText = ""
        selection = nil
    }

    // MARK: - Project selection

    /// Enter Project scope WITHOUT nagging: reuse the active project, else the first saved
    /// one, and only pop the picker on a genuine first run (no projects at all).
    func enterProjectScope() {
        if selectedProject != nil {
            reload()
        } else if let first = savedProjects.first {
            setProject(first)
        } else {
            chooseProject()
        }
    }

    /// Open the folder picker to add/switch a project. Only the explicit "Add project…"
    /// action and first-run should call this — never a bare tab toggle.
    func chooseProject() {
        // Present on the NEXT runloop tick. Running a modal panel synchronously from inside
        // a SwiftUI view update can silently no-op; deferring escapes the update cycle and
        // activating brings the panel to the front.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose Project"
            panel.message = "Choose a project directory to scan its skills."
            if panel.runModal() == .OK, let url = panel.url {
                self.setProject(url)
            } else if self.selectedProject == nil {
                // Cancelled with nothing to show: activate a saved project, else go Global.
                if let first = self.savedProjects.first {
                    self.setProject(first)
                } else {
                    self.scopeMode = .global
                    self.reload()
                }
            }
            // Cancelled but a project is already active → just keep showing it.
        }
    }

    /// Switch to `url`. New projects are saved (persist indefinitely); switching to an
    /// already-saved one keeps the list order stable so positions don't jump around.
    func setProject(_ url: URL) {
        resetFilters()
        selectedProject = url
        scopeMode = .project
        if !savedProjects.contains(where: { $0.path == url.path }) {
            savedProjects.insert(url, at: 0)
            persistProjects()
        }
        persistActiveProject()
        reload()
    }

    /// Forget a saved project. If it was the current one, fall back to another saved
    /// project, or to Global if none remain.
    func removeProject(_ url: URL) {
        savedProjects.removeAll { $0.path == url.path }
        persistProjects()
        if selectedProject?.path == url.path {
            selectedProject = savedProjects.first
            persistActiveProject()
            if selectedProject == nil { scopeMode = .global }
            reload()
        }
    }

    private func persistProjects() {
        UserDefaults.standard.set(savedProjects.map(\.path), forKey: projectsKey)
    }

    private func persistActiveProject() {
        UserDefaults.standard.set(selectedProject?.path, forKey: activeProjectKey)
    }

    private func persistScope() {
        UserDefaults.standard.set(scopeMode.rawValue, forKey: scopeKey)
    }

    // MARK: - Loading

    func reload() {
        isLoading = true
        reloadGeneration &+= 1
        let gen = reloadGeneration
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
                // Drop a scan that a newer reload (e.g. a scope switch) has superseded,
                // so a slow global scan can't overwrite the current project's list.
                guard gen == self.reloadGeneration else { return }
                self.skills = scanned
                self.cliAvailable = cli
                self.gitAvailable = git
                self.isLoading = false
                // Resolve a pending post-mutation selection by NAME (first canonical match).
                if let nm = self.pendingSelectName {
                    self.selection = scanned.first { $0.name == nm }?.id
                    self.pendingSelectName = nil
                }
                if let sel = self.selection, !scanned.contains(where: { $0.id == sel }) {
                    self.selection = nil
                }
                // If a source filter's source vanished from the scan, fall back to All.
                if case .source(let src) = self.sidebarFilter,
                   !self.sources.contains(where: { $0.name == src }) {
                    self.sidebarFilter = .library(.all)
                }
                self.reconcileSelection()
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

    /// Centralizes the off-main CLI run + status reporting. `work` runs detached; status
    /// and reload land back on the main actor. `onSuccessSelect` re-selects a skill by
    /// name once it (re)appears after the reload.
    private func perform(_ id: ActionID, _ label: String, onSuccessSelect: String? = nil, _ work: @escaping () -> CLIResult) {
        actionStatus = .running(id, label)
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let r = work()
            await MainActor.run {
                if r.ok {
                    self.actionStatus = .success(id, label)
                    if let sel = onSuccessSelect { self.pendingSelectName = sel }
                } else {
                    self.actionStatus = .failure(id, r.message)
                    self.lastError = r.message
                }
                self.reload()
            }
        }
    }

    /// INSTALL a package or specific skill from a source ref into chosen agents (CLI only).
    func install(ref: String, skill: String? = nil, agents: [Agent] = [], copy: Bool = false) {
        let scope = currentScope
        let selectHint = skill ?? Self.lastPathComponent(of: ref)
        perform(.install, "Installing", onSuccessSelect: selectHint) {
            SkillsCLIService.add(ref: ref, skill: skill, agents: agents, scope: scope, copy: copy)
        }
    }

    /// UPDATE an installed skill to the latest version of its source.
    func updateSkill(_ skill: Skill) {
        let scope = skill.scope
        let name = skill.name
        perform(.update(skill.id), "Updating \(name)") { SkillsCLIService.update(name: name, scope: scope) }
    }

    /// REMOVE a skill fully, or unwire it from specific agents when `agents` is non-empty.
    func removeSkill(_ skill: Skill, agents: [Agent] = []) {
        let scope = skill.scope
        let name = skill.name
        let label = agents.isEmpty ? "Removing \(name)" : "Unwiring \(name)"
        perform(.remove(skill.id), label) { SkillsCLIService.remove(name: name, agents: agents, scope: scope) }
    }

    /// "owner/repo" → "repo" select hint for post-install reselection.
    private static func lastPathComponent(of ref: String) -> String {
        ref.split(separator: "/").last.map(String.init) ?? ref
    }

    /// Wire a skill into an agent by creating the missing symlink to its canonical dir,
    /// mirroring `npx skills`: write the canonical files to `.agents/skills`, then a
    /// RELATIVE symlink (e.g. `../../.agents/skills/<name>`) in the agent's own dir.
    /// Only non-universal agents (Claude Code) ever need this; reversible.
    ///
    /// Uses the raw relative-symlink path (offline, correct for the single Claude-Code-
    /// missing drift case) rather than the CLI — `skills add <localPath>` is built for
    /// remote refs and may re-clone an already-canonical skill.
    func wire(_ skill: Skill, into agent: Agent) {
        let id = ActionID.wire(skill.id, agent)
        actionStatus = .running(id, "Wiring \(agent.displayName)")
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let r = Self.rawSymlinkWire(skill, into: agent)
            await MainActor.run {
                if r.ok { self.actionStatus = .success(id, "Wired \(agent.displayName)") }
                else { self.actionStatus = .failure(id, r.message); self.lastError = r.message }
                self.reload()
            }
        }
    }

    /// Batch-wire every skill that has missing-agent drift.
    func fixAllDrift() {
        let targets = skills.filter { !$0.driftMissing.isEmpty }
        guard !targets.isEmpty else { return }
        actionStatus = .running(.fixAllDrift, "Fixing drift")
        lastError = nil
        Task.detached(priority: .userInitiated) {
            var failures = 0
            var done = 0
            for s in targets {
                for agent in s.driftMissing {
                    let r = Self.rawSymlinkWire(s, into: agent)
                    if !r.ok { failures += 1 }
                }
                done += 1
                let progress = done, total = targets.count
                await MainActor.run { self.actionStatus = .running(.fixAllDrift, "Fixed \(progress) of \(total)") }
            }
            let failureCount = failures, total = targets.count
            await MainActor.run {
                self.actionStatus = failureCount == 0
                    ? .success(.fixAllDrift, "Fixed drift on \(total) skills")
                    : .failure(.fixAllDrift, "\(failureCount) failed")
                if failureCount > 0 { self.lastError = "\(failureCount) skill(s) failed to wire." }
                self.reload()
            }
        }
    }

    /// Create the relative agent-dir symlink for a skill. Returns a CLIResult-shaped
    /// outcome (do/catch, NOT try?) so any FileManager failure surfaces to the UI.
    /// `nonisolated` — touches only FileManager/strings, and is called off the main
    /// actor from the detached tasks in wire()/fixAllDrift().
    nonisolated static func rawSymlinkWire(_ skill: Skill, into agent: Agent) -> CLIResult {
        let dir: URL
        if skill.scope.isGlobal {
            guard let g = agent.globalSkillDirs.first else {
                return CLIResult(exitCode: 1, stdout: "", stderr: "No global skills dir for \(agent.displayName).")
            }
            dir = g
        } else if let root = skill.scope.projectRoot, let rel = agent.projectSkillDirs.first {
            dir = URL(fileURLWithPath: root).appendingPathComponent(rel)
        } else {
            return CLIResult(exitCode: 1, stdout: "", stderr: "No skills dir for \(agent.displayName).")
        }

        let fm = FileManager.default
        let link = dir.appendingPathComponent(skill.name)
        let relTarget = relativePath(from: dir.path, to: skill.canonicalPath)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Only clear an existing SYMLINK (stale/broken) — never recursively delete a
            // real file or directory that happens to sit at the link path. lstat semantics:
            // attributesOfItem does not follow the link, so a symlink reports .typeSymbolicLink.
            if let attrs = try? fm.attributesOfItem(atPath: link.path) {
                if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                    try fm.removeItem(at: link)
                } else {
                    return CLIResult(exitCode: 1, stdout: "",
                        stderr: "A real file already exists at \(link.path); refusing to overwrite it.")
                }
            }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: relTarget)
            return CLIResult(exitCode: 0, stdout: "Wired \(skill.name) → \(agent.displayName)", stderr: "")
        } catch {
            return CLIResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }
    }

    /// Relative path from a directory to a target (so symlinks stay portable, like the CLI's).
    nonisolated private static func relativePath(from base: String, to target: String) -> String {
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
