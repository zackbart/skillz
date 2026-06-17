import SwiftUI

struct SkillListView: View {
    @EnvironmentObject var state: AppState
    @State private var showInstall = false
    @State private var showAddMcp = false

    /// True when in Project scope but no project is chosen yet — install needs a target.
    private var needsProject: Bool {
        state.scopeMode == .project && state.selectedProject == nil
    }

    var body: some View {
        Group {
            if state.kind == .mcp {
                McpListView()
            } else {
                // Compute the filtered list once per render — body re-evaluates on every
                // @Published change and this branch reads it for both the List and the overlay.
                let skills = state.filteredSkills
                List(skills, selection: $state.selection) { skill in
                    SkillRow(skill: skill)
                }
                .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search skills")
                .overlay {
                    if state.isLoading && state.skills.isEmpty {
                        ProgressView()
                    } else if skills.isEmpty {
                        ContentUnavailableView("No skills", systemImage: "tray",
                            description: Text(emptyHint))
                    }
                }
            }
        }
        .toolbar {
            // Fix-all-drift — only when there's drift; reflects in-progress status.
            if state.driftCount > 0 && state.kind == .skill {
                ToolbarItem(placement: .automatic) {
                    Button {
                        state.fixAllDrift()
                    } label: {
                        if let label = state.actionStatus.runningLabel(.fixAllDrift) {
                            Text(label)
                        } else {
                            Text("Fix all drift")
                        }
                    }
                    .tint(Theme.drift)
                    .controlSize(.small)
                    .disabled(state.actionStatus.isRunning || state.isLoading)
                    .help("Wire every skill that's declared but not linked")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if state.kind == .mcp {
                    Button { showAddMcp = true } label: {
                        Label("Add MCP server…", systemImage: "plus")
                    }
                    .tint(McpHarness.claudeCode.color)
                    .disabled(needsProject)
                    .help(needsProject ? "Choose a project first" : "Add an MCP server to your harnesses")
                } else {
                    Button { showInstall = true } label: {
                        Label("Install skill…", systemImage: "plus")
                    }
                    .tint(Agent.claude.color)
                    .disabled(needsProject)
                    .help(needsProject ? "Choose a project first" : "Install a skill from a source")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // Small inline refresh spinner so a reload of an already-populated list shows progress.
                if state.isLoading && !state.skills.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { state.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
                    .disabled(state.isLoading)
            }
        }
        .sheet(isPresented: $showInstall) { InstallSheet() }
        .sheet(isPresented: $showAddMcp) { McpServerSheet(mode: .add) }
    }

    private var emptyHint: String {
        if state.scopeMode == .project && state.selectedProject == nil {
            return "Choose a project to scan its skills."
        }
        return "Nothing matches the current filters."
    }
}

/// Install a skill (or whole package) from a source ref via the skills CLI.
struct InstallSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var ref = ""
    @State private var skillName = ""
    /// Snapshot of the status owned by THIS install, so an overlapping mutation can't fool us.
    @State private var didSubmit = false

    private var scopeReadout: String {
        if state.scopeMode == .project {
            return "Project: \(state.selectedProject?.lastPathComponent ?? "—")"
        }
        return "Global"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install skill").font(.title2).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 6) {
                Text("Source").font(.caption).foregroundStyle(.secondary)
                TextField("owner/repo or URL", text: $ref)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Skill name (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("install one named skill, or leave blank for all", text: $skillName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 6) {
                Image(systemName: "scope").font(.caption2)
                Text(scopeReadout).font(.caption).foregroundStyle(.secondary)
            }

            if !state.cliAvailable {
                Label("Requires the skills CLI on PATH", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.drift)
            }

            // In-flight / failure feedback owned by THIS submission (scoped to .install,
            // so a background reload or overlapping mutation can't alter it).
            if didSubmit {
                if let label = state.actionStatus.runningLabel(.install) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                } else if let msg = state.actionStatus.failureMessage(.install) {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Theme.drift)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Theme.drift.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
                    didSubmit = true
                    let trimmedSkill = skillName.trimmingCharacters(in: .whitespaces)
                    state.install(ref: ref.trimmingCharacters(in: .whitespaces),
                                  skill: trimmedSkill.isEmpty ? nil : trimmedSkill)
                }
                .buttonStyle(.glassProminent)
                .tint(Agent.claude.color)
                .keyboardShortcut(.defaultAction)
                .disabled(ref.trimmingCharacters(in: .whitespaces).isEmpty
                          || !state.cliAvailable
                          || state.actionStatus.isRunning)
            }
        }
        .padding(20)
        .frame(width: 420)
        // Dismiss once THIS install succeeds (ignores other actions' success).
        .onChange(of: state.actionStatus) { _, status in
            if didSubmit, status.didSucceed(.install) { dismiss() }
        }
    }
}

struct SkillRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(skill.name).fontWeight(.medium)
                if skill.diverged {
                    Tag(text: "diverged", color: Theme.drift)
                        .help("Another skill with this name exists in this scope (a same-name clash).")
                }
                if !skill.driftMissing.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.drift)
                        .help("Declared for \(skill.driftMissing.map(\.displayName).joined(separator: ", ")) but not wired")
                }
                Spacer()
                if let loc = skill.locationBadge {
                    Text(loc)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(skill.locationHelp ?? "Project location")
                }
                Image(systemName: skill.gitStatus.systemImage)
                    .font(.caption2)
                    .foregroundStyle(skill.gitStatus.color)
                    .help("\(skill.gitStatus.label) — \(skill.gitStatus.helpText)\(skill.linksDiverge ? " · links diverge" : "")")
            }
            if let s = skill.summary {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                // Canonical store covers all universal agents — one indicator, not a list.
                if skill.canonicalPresent {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Agent.agents.color)
                        .help("In .agents/skills — Codex, OpenCode & Pi read it directly")
                }
                // Claude Code reaches it via its own dir (symlink or real local files).
                if skill.access(.claude) == .wired {
                    Circle().fill(Agent.claude.color).frame(width: 7, height: 7)
                        .help(skill.isLocalDir(.claude)
                              ? "Claude Code · local files in .claude/skills"
                              : "Claude Code · symlinked")
                }
                if skill.isCLIManaged {
                    Image(systemName: "terminal")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("Managed by the skills CLI")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
