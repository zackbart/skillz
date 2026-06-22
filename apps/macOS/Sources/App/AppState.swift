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
    // MCP mutations
    case mcpAdd
    case mcpEdit(McpServer.ID)
    case mcpRemove(McpServer.ID)
    case mcpApply(McpServer.ID)
    case mcpToggle(McpServer.ID, McpHarness)
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
    case mcpHarness(McpHarness)
}

@MainActor
final class AppState: ObservableObject {
    // Navigation / filters
    @Published var kind: ResourceKind = .skill { didSet { if oldValue != kind { switchedKind() } } }
    @Published var scopeMode: ScopeMode = .global { didSet { persistScope() } }
    @Published var selectedProject: URL?
    /// Projects the user has saved — persisted indefinitely, switchable, removable.
    @Published var savedProjects: [URL] = []
    /// Remote machines the user has added (ssh targets / `~/.ssh/config` aliases), persisted.
    @Published var savedHosts: [String] = []
    /// The selected remote target, or nil for the local machine. Not persisted — every
    /// launch starts Local so the app never tries to reach out to a host on open.
    @Published var selectedHostTarget: String?
    // "Add remote host…" prompt state.
    @Published var showAddHost = false
    @Published var newHostInput = ""
    // Password prompt state — non-nil target shows the secure prompt (key auth was refused).
    @Published var passwordPromptTarget: String?
    @Published var passwordInput = ""
    // Single-select sidebar filter (native macOS list selection). Reconciles the skill
    // selection on change so the detail pane never shows a filtered-out skill.
    @Published var sidebarFilter: SidebarFilter = .library(.all) { didSet { reconcileSelection() } }

    // Data — skills
    @Published var skills: [Skill] = []
    @Published var selection: Skill.ID?
    // Data — MCP servers (a parallel axis, kept honest rather than forced through skill state)
    @Published var mcpServers: [McpServer] = []
    @Published var mcpSelection: McpServer.ID?
    @Published var mcpIssues: [McpConfigIssue] = []
    @Published var searchText = "" { didSet { reconcileSelection() } }
    @Published var isLoading = false
    @Published var cliAvailable = false
    @Published var gitAvailable = false

    // Mutation surface
    @Published var actionStatus: ActionStatus = .idle   // drives spinners / inline confirmations
    @Published var lastError: String?                   // alert binding (non-nil ⇒ show alert)

    /// Live Agents axis — a parallel async source over the Herdr socket, NOT a filesystem
    /// scan (so it bypasses scanCache/HostIO/FileWatcher entirely). See AgentsSessionModel.
    let agentsModel = AgentsSessionModel()
    @Published var pendingSelectName: String?           // name to select once it appears post-reload
    @Published var pendingMcpSelectName: String?         // MCP equivalent (re-select after a write)

    private var watcher: FileWatcher?
    private let projectsKey = "recentProjects" // key kept for continuity with existing data
    private let activeProjectKey = "activeProject"
    private let scopeKey = "scopeMode"
    private let hostsKey = "remoteHosts"
    /// Bumped on every reload; a detached scan only applies if it's still the latest.
    private var reloadGeneration = 0
    /// Scan-cache key: a scope is only unique WITHIN a host, so remote and local scans of
    /// the "same" scope don't collide. (Slice 1 makes `currentHost` non-local.)
    private struct ScanKey: Hashable { let host: Host; let scope: ResourceScope }
    /// Last-known scan per (host, scope). Seeded into `skills` instantly on a switch, then a
    /// fresh scan always follows and overwrites — a pure render optimization, not a staleness risk.
    private var scanCache: [ScanKey: [Skill]] = [:]
    /// Which key `skills` currently reflects — drives the seed-on-switch path.
    private var skillsScope: ScanKey?
    /// MCP equivalents of the above (same seed-on-switch / generation-guard discipline).
    private var mcpScanCache: [ScanKey: McpScanResult] = [:]
    private var mcpScope: ScanKey?
    /// Skill dirs the latest scan looked at; what the FileWatcher should watch. Captured
    /// from the scan (incl. nested ancestor/descendant bases) so nested edits fire reloads.
    private var watchPaths: [String] = []

    init() {
        savedProjects = (UserDefaults.standard.array(forKey: projectsKey) as? [String])?
            .map { URL(fileURLWithPath: $0) } ?? []
        savedHosts = (UserDefaults.standard.array(forKey: hostsKey) as? [String]) ?? []
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

    // MCP-side counts (mirror the skill counts; used by the kind-aware sidebar).
    var mcpDivergedCount: Int { mcpServers.filter { $0.definitionDiverges }.count }
    var mcpDriftCount: Int { mcpServers.filter { !$0.supportedButMissing.isEmpty }.count }
    func mcpCount(for harness: McpHarness) -> Int {
        mcpServers.filter { $0.presentIn.contains(harness) }.count
    }

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

    /// The host the current scope scans. Always `.local` today; Slice 1 makes it real.
    /// The machine the current scan targets: a saved remote, or local.
    var currentHost: Host {
        selectedHostTarget.flatMap(Host.parse) ?? .local
    }

    /// Remote scopes are read-only and global-only (see D7) — drives UI gating.
    var isRemote: Bool { currentHost != .local }

    // MARK: - Machine selection

    /// Switch the scan to a remote host (read-only, global). Forces Global scope: remote
    /// project discovery isn't modelled yet (D7), so we never strand in Project scope.
    /// Probes connectivity first; key auth is tried, and on refusal the user is prompted
    /// for a password (held only for the session).
    func selectHost(_ target: String) {
        resetFilters()
        selectedHostTarget = target
        scopeMode = .global
        probeAndReload(target)
    }

    /// Probe `target` off-main; reload on success, prompt for a password on auth refusal,
    /// or surface a connection error.
    private func probeAndReload(_ target: String) {
        isLoading = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let result = RemoteHostIO(target: target).connect()
            await MainActor.run {
                guard self.selectedHostTarget == target else { return } // user moved on
                switch result {
                case .ok:
                    self.reload()
                case .needsPassword:
                    self.isLoading = false
                    self.passwordInput = ""
                    self.passwordPromptTarget = target
                case .failed(let msg):
                    self.isLoading = false
                    self.lastError = "Couldn’t connect to \(target): \(msg)"
                    self.selectLocal()
                }
            }
        }
    }

    /// User submitted a password for the prompted host: keep it for the session and retry.
    func submitPassword() {
        guard let target = passwordPromptTarget, !passwordInput.isEmpty else { return }
        RemoteCredentials.set(passwordInput, for: target)
        passwordInput = ""
        passwordPromptTarget = nil
        probeAndReload(target)
    }

    /// User cancelled the password prompt: drop back to Local.
    func cancelPassword() {
        passwordPromptTarget = nil
        passwordInput = ""
        selectLocal()
    }

    /// Switch back to the local machine.
    func selectLocal() {
        guard selectedHostTarget != nil else { return }
        resetFilters()
        selectedHostTarget = nil
        reload()
    }

    /// Add (and select) a remote host from user input ("user@host" or an ssh alias).
    func addRemoteHost(_ input: String) {
        guard let host = Host.parse(input) else { return }
        let target = host.target
        if !savedHosts.contains(target) {
            savedHosts.append(target)
            UserDefaults.standard.set(savedHosts, forKey: hostsKey)
        }
        selectHost(target)
    }

    /// Forget a saved remote host; clear any session password and fall back to Local.
    func removeHost(_ target: String) {
        savedHosts.removeAll { $0 == target }
        UserDefaults.standard.set(savedHosts, forKey: hostsKey)
        RemoteCredentials.clear(target)
        if selectedHostTarget == target { selectLocal() }
    }

    var sources: [(name: String, count: Int)] {
        var m: [String: Int] = [:]
        for s in skills {
            for g in s.sourceGroups { m[g, default: 0] += 1 }
        }
        // CLI sources first, then the "Local · …" folder groups; alphabetical within each.
        return m.sorted { a, b in
            let al = a.key.hasPrefix("Local"), bl = b.key.hasPrefix("Local")
            if al != bl { return !al }
            return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
        }.map { ($0.key, $0.value) }
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
            list = list.filter { $0.sourceGroups.contains(src) }
        case .mcpHarness: break // MCP-only filter; ignored in skill mode
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter { $0.searchHaystack.contains(q) }
        }
        return list
    }

    /// Resolve against the VISIBLE list so the detail pane never shows a filtered-out skill.
    var selectedSkill: Skill? {
        guard let selection else { return nil }
        return filteredSkills.first { $0.id == selection }
    }

    var filteredMcpServers: [McpServer] {
        var list = mcpServers
        switch sidebarFilter {
        case .library(.all): break
        case .library(.diverged): list = list.filter { $0.definitionDiverges }
        case .library(.drift): list = list.filter { !$0.supportedButMissing.isEmpty }
        case .mcpHarness(let h): list = list.filter { $0.presentIn.contains(h) }
        case .agent, .source: break // skill-only filters; ignored in MCP mode
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) || ($0.summary?.lowercased().contains(q) ?? false)
            }
        }
        return list
    }

    var selectedMcpServer: McpServer? {
        guard let mcpSelection else { return nil }
        return filteredMcpServers.first { $0.id == mcpSelection }
    }

    // MARK: - Selection / filter coherence

    /// Clear the selection if it's no longer in the visible list (called from filter didSets).
    /// Reconciles whichever axis is active so the detail pane never shows a filtered-out row.
    func reconcileSelection() {
        switch kind {
        case .skill:
            if let sel = selection, !filteredSkills.contains(where: { $0.id == sel }) {
                selection = nil
            }
        case .mcp:
            if let sel = mcpSelection, !filteredMcpServers.contains(where: { $0.id == sel }) {
                mcpSelection = nil
            }
        case .agents:
            // Agents selection lives in agentsModel and is reconciled there on refresh.
            break
        }
    }

    /// Reset all filters + selection. Called on scope/project/kind change so carried-over
    /// agent/source/lib/search state can't silently empty the list. Selections are set last
    /// so the net result is always `selection == nil` regardless of didSet ordering.
    func resetFilters() {
        sidebarFilter = .library(.all)
        searchText = ""
        selection = nil
        mcpSelection = nil
    }

    /// Switching the kind switcher resets filters and loads the new axis. A `.source` filter
    /// (skill-only) can't survive into MCP mode, and `resetFilters` already clears it.
    private func switchedKind() {
        resetFilters()
        // A pending post-mutation selection belongs to the axis it was set on; switching axes
        // strands it (each reloader only reads its own), so clear both to avoid a stale re-select.
        pendingSelectName = nil
        pendingMcpSelectName = nil
        reload()
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
        switch kind {
        case .skill: reloadSkills()
        case .mcp: reloadMcp()
        case .agents: Task { await agentsModel.refresh() }
        }
    }

    private func reloadSkills() {
        let key = ScanKey(host: currentHost, scope: currentScope)
        // On a scope/project SWITCH, paint the target scope's last-known list immediately
        // (instant feel), or clear the previous scope's list so a stale wrong-project list
        // never lingers. The background scan below always refreshes it.
        if skillsScope != key {
            skills = scanCache[key] ?? []
            skillsScope = key
            reconcileSelection()
        }
        isLoading = true
        reloadGeneration &+= 1
        let gen = reloadGeneration
        let mode = scopeMode
        let project = selectedProject
        let host = currentHost
        Task.detached(priority: .userInitiated) {
            let scanned: [Skill]
            switch mode {
            case .global: scanned = SkillScanner.scanGlobal(host: host)
            case .project: scanned = project.map { SkillScanner.scanProject(root: $0, host: host) } ?? []
            }
            // Always watch the canonical store; in project scope also watch every skill dir
            // the scan touched (incl. nested bases) so nested edits trigger a reload.
            // Watcher paths are local-only (FSEvents), so resolve against LocalHostIO.
            var built = Agent.allCases.flatMap { $0.globalSkillDirs(LocalHostIO()).map(\.path) }
            if mode == .project, let project {
                built += SkillScanner.projectSkillDirPaths(from: project, io: LocalHostIO())
            }
            let watch = built
            let cli = SkillsCLIService.isAvailable(host.makeIO())
            let git = GitStatusService.isAvailable(host.makeIO())
            await MainActor.run {
                // Drop a scan that a newer reload (e.g. a scope switch) has superseded,
                // so a slow global scan can't overwrite the current project's list.
                guard gen == self.reloadGeneration else { return }
                self.skills = scanned
                self.scanCache[key] = scanned
                self.skillsScope = key
                self.watchPaths = watch
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

    private func reloadMcp() {
        // MCP scanning is local-only in Slice 1 (McpScanner isn't host-threaded, D7) — never
        // run it against a remote selection, which would silently show LOCAL servers.
        if isRemote {
            mcpServers = []; mcpIssues = []; mcpSelection = nil; isLoading = false
            watcher?.stop()
            return
        }
        let key = ScanKey(host: currentHost, scope: currentScope)
        if mcpScope != key {
            let cached = mcpScanCache[key]
            mcpServers = cached?.servers ?? []
            mcpIssues = cached?.issues ?? []
            mcpScope = key
            reconcileSelection()
        }
        isLoading = true
        reloadGeneration &+= 1
        let gen = reloadGeneration
        let mode = scopeMode
        let project = selectedProject
        Task.detached(priority: .userInitiated) {
            let result: McpScanResult
            switch mode {
            case .global: result = McpScanner.scanGlobal()
            case .project: result = project.map { McpScanner.scanProject(root: $0) } ?? .empty
            }
            let watch = McpScanner.configWatchPaths(
                global: mode == .global, root: mode == .project ? project : nil)
            let git = GitStatusService.isAvailable(LocalHostIO())
            await MainActor.run {
                guard gen == self.reloadGeneration else { return }
                self.mcpServers = result.servers
                self.mcpIssues = result.issues
                self.mcpScanCache[key] = result
                self.mcpScope = key
                self.watchPaths = watch
                self.gitAvailable = git
                self.isLoading = false
                if let nm = self.pendingMcpSelectName {
                    self.mcpSelection = result.servers.first { $0.name == nm }?.id
                    self.pendingMcpSelectName = nil
                }
                if let sel = self.mcpSelection, !result.servers.contains(where: { $0.id == sel }) {
                    self.mcpSelection = nil
                }
                self.reconcileSelection()
                self.updateWatcher()
            }
        }
    }

    private func updateWatcher() {
        // FSEvents is local-only (no SSH analog, D7): remote scopes refresh via the manual
        // Refresh button, not a live watcher.
        guard !isRemote else { watcher?.stop(); return }
        // Watch exactly the dirs the latest scan looked at (canonical store + every project
        // skill dir incl. nested bases), captured in `watchPaths` so a symlinked skill's
        // real files and nested-package skills both fire reloads.
        watcher?.start(paths: watchPaths)
    }

    // MARK: - Mutations

    /// Centralizes the off-main CLI run + status reporting. `work` runs detached; status
    /// and reload land back on the main actor. `onSuccessSelect` re-selects a skill by
    /// name once it (re)appears after the reload.
    private func perform(_ id: ActionID, _ label: String, onSuccessSelect: String? = nil, _ work: @escaping () -> CLIResult) {
        guard !isRemote else { return } // remote scopes are read-only (D7)
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
            SkillsCLIService.add(ref: ref, skill: skill, agents: agents, scope: scope, copy: copy, io: LocalHostIO())
        }
    }

    /// UPDATE an installed skill to the latest version of its source.
    func updateSkill(_ skill: Skill) {
        let scope = skill.scope
        let name = skill.name
        perform(.update(skill.id), "Updating \(name)") { SkillsCLIService.update(name: name, scope: scope, io: LocalHostIO()) }
    }

    /// REMOVE a skill fully, or unwire it from specific agents when `agents` is non-empty.
    func removeSkill(_ skill: Skill, agents: [Agent] = []) {
        let scope = skill.scope
        let name = skill.name
        let label = agents.isEmpty ? "Removing \(name)" : "Unwiring \(name)"
        perform(.remove(skill.id), label) { SkillsCLIService.remove(name: name, agents: agents, scope: scope, io: LocalHostIO()) }
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
        guard !isRemote else { return } // remote scopes are read-only (D7)
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
        guard !isRemote else { return } // remote scopes are read-only (D7)
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
            guard let g = agent.globalSkillDirs(LocalHostIO()).first else {
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

    // MARK: - MCP mutations

    /// Add a new server into the chosen harnesses' configs at the current scope (root base).
    func addMcpServer(name: String, def: PortableMcpDefinition, targets: [McpHarness]) {
        let scope = currentScope
        let jobs: [(McpWriteEngine.Op, McpConfigLocation)] = targets.compactMap { h in
            guard let loc = mcpLocation(h, scope: scope, logicalLocation: "") else { return nil }
            return (.upsert(name: name, def: def, enabled: true), loc)
        }
        runMcpWrites(.mcpAdd, "Adding \(name)", jobs, selectName: name)
    }

    /// Re-apply an edited definition into every harness the server already lives in,
    /// preserving each harness's current enabled state (and its agent-local fields).
    func editMcpServer(_ server: McpServer, def: PortableMcpDefinition) {
        var jobs: [(McpWriteEngine.Op, McpConfigLocation)] = []
        for h in server.presentIn {
            guard let loc = server.origins[h]?.first(where: { $0.isPrimary }) ?? server.origins[h]?.first
            else { continue }
            let enabled = server.entries[h]?.enabled ?? true
            jobs.append((.upsert(name: server.name, def: def, enabled: enabled), loc))
        }
        runMcpWrites(.mcpEdit(server.id), "Saving \(server.name)", jobs, selectName: server.name)
    }

    /// Copy the server into every harness that supports its transport but doesn't have it.
    func applyToSupported(_ server: McpServer) {
        guard let def = server.representativePortable else { return }
        let jobs: [(McpWriteEngine.Op, McpConfigLocation)] = server.supportedButMissing.compactMap { h in
            guard let loc = mcpLocation(h, scope: server.scope, logicalLocation: server.logicalLocation)
            else { return nil }
            return (.upsert(name: server.name, def: def, enabled: true), loc)
        }
        runMcpWrites(.mcpApply(server.id), "Applying \(server.name)", jobs, selectName: server.name)
    }

    /// Remove the server from the given harnesses (all of their origin files), or from every
    /// harness it lives in when `harnesses` is empty.
    func removeMcpServer(_ server: McpServer, from harnesses: [McpHarness] = []) {
        let targets = harnesses.isEmpty ? Array(server.presentIn) : harnesses
        var jobs: [(McpWriteEngine.Op, McpConfigLocation)] = []
        for h in targets {
            for loc in server.origins[h] ?? [] { jobs.append((.remove(name: server.name), loc)) }
        }
        let keepsSome = !Set(targets).isSuperset(of: server.presentIn)
        runMcpWrites(.mcpRemove(server.id), "Removing \(server.name)", jobs,
                     selectName: keepsSome ? server.name : nil)
    }

    /// Enable / disable the server in a single harness (only opencode & Codex can express this).
    func setMcpEnabled(_ server: McpServer, harness: McpHarness, enabled: Bool) {
        guard let def = server.entries[harness]?.portable,
              let loc = server.origins[harness]?.first(where: { $0.isPrimary }) ?? server.origins[harness]?.first
        else { return }
        runMcpWrites(.mcpToggle(server.id, harness), enabled ? "Enabling" : "Disabling",
                     [(.upsert(name: server.name, def: def, enabled: enabled), loc)],
                     selectName: server.name)
    }

    /// Resolve the primary config location for a harness at a scope + project subpackage.
    private func mcpLocation(_ h: McpHarness, scope: ResourceScope, logicalLocation: String) -> McpConfigLocation? {
        switch scope {
        case .global:
            return McpConfigDescriptor.globalLocations(h).first
        case .project(let root):
            var base = URL(fileURLWithPath: root)
            if !logicalLocation.isEmpty && !logicalLocation.hasPrefix("↑") {
                base = base.appendingPathComponent(logicalLocation)
            }
            return McpConfigDescriptor.projectLocations(h, base: base).first
        }
    }

    /// Run a batch of config writes off the main actor, aggregating failures, then reload.
    /// Mirrors `perform` but for the MCP write engine (FileManager writes, not the CLI).
    private func runMcpWrites(_ id: ActionID, _ label: String,
                              _ jobs: [(McpWriteEngine.Op, McpConfigLocation)],
                              selectName: String?) {
        guard !isRemote else { return } // remote scopes are read-only (D7)
        guard !jobs.isEmpty else { return }
        actionStatus = .running(id, label)
        lastError = nil
        Task.detached(priority: .userInitiated) {
            var collected: [String] = []
            for (op, loc) in jobs {
                do { try McpWriteEngine.apply(op, at: loc) }
                catch { collected.append("\(loc.harness.displayName): \(error)") }
            }
            let failures = collected
            await MainActor.run {
                if failures.isEmpty {
                    self.actionStatus = .success(id, label)
                    if let nm = selectName { self.pendingMcpSelectName = nm }
                } else {
                    let msg = failures.joined(separator: "\n")
                    self.actionStatus = .failure(id, msg)
                    self.lastError = msg
                }
                self.reload()
            }
        }
    }

    func openInEditor(_ skill: Skill) {
        // Remote skills' URLs are remote paths, not local files — opening them would point
        // at the wrong place (and "edit" is a write affordance, out of scope for remote).
        guard skill.host == .local else { return }
        NSWorkspace.shared.open(skill.skillMdURL)
    }

    /// Open a bundled file in its default app, or reveal a packaged subdirectory in Finder.
    func openBundledFile(_ file: BundledFile) {
        guard !isRemote else { return }
        if file.isDirectory {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } else {
            NSWorkspace.shared.open(file.url)
        }
    }
}
