import SwiftUI

struct SkillDetailView: View {
    let skill: Skill
    @EnvironmentObject var state: AppState
    @State private var wireTarget: Agent?
    @State private var confirmRemove = false

    /// This skill is a candidate for `skills update` only when CLI-managed and provenanced.
    private var canUpdate: Bool {
        skill.isCLIManaged && (skill.provenance?.source.isEmpty == false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                managementRow
                agentsSection
                if !skill.driftMissing.isEmpty { driftCard }
                if let p = skill.provenance, !p.source.isEmpty { provenanceSection(p) }
                if !skill.frontmatterKeys.isEmpty { frontmatterSection }
                bodySection
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(skill.name)
        .confirmationDialog(
            "Wire \(skill.name) into \(wireTarget?.displayName ?? "")?",
            isPresented: Binding(get: { wireTarget != nil }, set: { if !$0 { wireTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Create symlink") { if let a = wireTarget { state.wire(skill, into: a); wireTarget = nil } }
            Button("Cancel", role: .cancel) { wireTarget = nil }
        } message: {
            Text("Creates a symlink in the agent's skills directory pointing at the canonical skill.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text(skill.name).font(.largeTitle).fontWeight(.bold)
                if skill.diverged { Tag(text: "diverged", color: Theme.drift) }
            }
            if let s = skill.summary {
                Text(s).font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Image(systemName: "link").font(.caption2)
                Text(skill.canonicalPath).font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
    }

    private var managementRow: some View {
        HStack(spacing: 8) {
            pill(skill.gitStatus.label, systemImage: skill.gitStatus.systemImage, color: skill.gitStatus.color)
            if skill.linksDiverge {
                pill("links diverge", systemImage: "arrow.triangle.branch", color: Theme.drift)
            }
            pill(skill.isCLIManaged ? "CLI-managed" : "Manual",
                 systemImage: skill.isCLIManaged ? "terminal" : "hand.raised",
                 color: .secondary)

            Spacer()

            if canUpdate {
                Button {
                    state.updateSkill(skill)
                } label: {
                    if state.actionStatus.isRunning {
                        HStack(spacing: 5) { ProgressView().controlSize(.small); Text("Updating…") }
                    } else {
                        Label("Update", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!state.cliAvailable || state.actionStatus.isRunning)
                .help(state.cliAvailable ? "Update to the latest version of its source" : "Requires the skills CLI")
            }

            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Label("Remove…", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!state.cliAvailable || state.actionStatus.isRunning)
            .help(state.cliAvailable ? "Uninstall this skill" : "Requires the skills CLI")
            .confirmationDialog(
                "Remove \(skill.name)?",
                isPresented: $confirmRemove,
                titleVisibility: .visible
            ) {
                Button("Remove \(skill.name)", role: .destructive) { state.removeSkill(skill) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Uninstalls the skill via the skills CLI.")
            }
        }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Available to")
            FlowRow(spacing: 7) {
                // Canonical store = every universal agent at once. One chip, not a list.
                if skill.canonicalPresent {
                    chip("Canonical · .agents/skills", color: Agent.agents.color,
                         systemImage: "shippingbox.fill", filled: true)
                }
                // Claude Code is the only agent that needs its own wiring.
                if skill.access(.claude) == .wired {
                    chip("Claude Code · symlinked", color: Agent.claude.color,
                         systemImage: "link.circle.fill", filled: true)
                }
                // Unusual: direct (non-canonical) installs into an agent's own dir.
                if !skill.canonicalPresent {
                    ForEach(Agent.displayAgents.filter { skill.wiredAgents.contains($0) && $0 != .claude }) { a in
                        chip("\(a.displayName) · symlinked", color: a.color,
                             systemImage: "link.circle.fill", filled: true)
                    }
                }
                ForEach(Array(skill.driftMissing).sorted { $0.rawValue < $1.rawValue }) { agent in
                    chip("\(agent.displayName) · declared", color: Theme.drift, systemImage: nil, ghost: true)
                }
            }
            if skill.canonicalPresent {
                Text("Codex, OpenCode & Pi read from .agents/skills directly — only Claude Code needs a symlink.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var driftCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Drift", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: 0x8A6400))
            Text("Declared for \(skill.driftMissing.map(\.displayName).joined(separator: ", ")) but not wired on disk.")
                .font(.callout)
                .foregroundStyle(Color(hex: 0x7A5800))
            HStack(spacing: 8) {
                ForEach(Array(skill.driftMissing).sorted { $0.rawValue < $1.rawValue }) { agent in
                    Button {
                        wireTarget = agent
                    } label: {
                        if state.actionStatus.isRunning {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("Wiring…")
                            }
                        } else {
                            Text("Wire into \(agent.displayName)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color(hex: 0xB8860B))
                    .disabled(state.actionStatus.isRunning)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.drift.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.drift.opacity(0.3)))
    }

    private func provenanceSection(_ p: SkillProvenance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Provenance")
            kv("Source", p.source)
            if let u = p.sourceURL { kv("Repo", u) }
            if let path = p.skillPath { kv("Path", path) }
            if let up = p.updatedAt { kv("Updated", up) }
            if let h = p.folderHash { kv("Hash", String(h.prefix(12))) }
            if let plugin = p.pluginName { kv("Plugin", plugin) }
        }
    }

    private var frontmatterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Frontmatter")
            Text(skill.frontmatterKeys.joined(separator: ", "))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("SKILL.md")
                Spacer()
                Button { state.openInEditor(skill) } label: {
                    Label("Edit", systemImage: "pencil").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(skill.bodyMarkdown)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func pill(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
            .foregroundStyle(color == .secondary ? .secondary : color)
    }

    private func chip(_ text: String, color: Color, systemImage: String?, filled: Bool = false, ghost: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(ghost ? Color.clear : color.opacity(0.14), in: Capsule())
        .overlay {
            if ghost { Capsule().strokeBorder(color.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
        }
        .foregroundStyle(color)
    }
}

/// Simple wrapping HStack for chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
