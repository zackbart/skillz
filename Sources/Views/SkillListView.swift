import SwiftUI

struct SkillListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(state.filteredSkills, selection: $state.selection) { skill in
            SkillRow(skill: skill)
        }
        .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search skills")
        .overlay {
            if state.isLoading && state.skills.isEmpty {
                ProgressView()
            } else if state.filteredSkills.isEmpty {
                ContentUnavailableView("No skills", systemImage: "tray",
                    description: Text(emptyHint))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { state.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
                    .disabled(state.isLoading)
            }
        }
    }

    private var emptyHint: String {
        if state.scopeMode == .project && state.selectedProject == nil {
            return "Choose a project to scan its skills."
        }
        return "Nothing matches the current filters."
    }
}

struct SkillRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(skill.name).fontWeight(.medium)
                if skill.diverged { Tag(text: "diverged", color: Theme.drift) }
                if !skill.driftMissing.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.drift)
                        .help("Declared for \(skill.driftMissing.map(\.displayName).joined(separator: ", ")) but not wired")
                }
                Spacer()
                Image(systemName: skill.gitStatus.systemImage)
                    .font(.caption2)
                    .foregroundStyle(skill.gitStatus.color)
                    .help("Git: \(skill.gitStatus.label)\(skill.linksDiverge ? " · links diverge" : "")")
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
                // Claude Code is the only agent that needs its own symlink.
                if skill.access(.claude) == .wired {
                    Circle().fill(Agent.claude.color).frame(width: 7, height: 7)
                        .help("Claude Code · symlinked")
                }
                // Unusual case: a skill installed directly into an agent dir, not canonical.
                if !skill.canonicalPresent {
                    ForEach(Agent.displayAgents.filter { skill.wiredAgents.contains($0) && $0 != .claude }) { a in
                        Circle().fill(a.color).frame(width: 7, height: 7).help("\(a.displayName) · symlinked")
                    }
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
