import SwiftUI
import HerdrKit

/// Live list of agent panes from the Herdr socket. T5a is plain-but-correct;
/// T5b styles rows to match the mockup. Selection resolves the transcript.
struct AgentsListView: View {
    @ObservedObject var model: AgentsSessionModel

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(model.panes, id: \.paneID) { pane in
                AgentPaneRow(pane: pane).tag(pane.paneID)
            }
        }
        .overlay {
            if model.panes.isEmpty, let status = model.status {
                ContentUnavailableView("No agents", systemImage: "tray",
                                       description: Text(status))
            }
        }
        // Poll topology while the list is on screen so panes appear/vanish on
        // their own; .task cancels the loop on disappear. Toolbar Refresh still works.
        // ponytail: 2s poll, swap for Herdr's event stream if it feels laggy/chatty.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Drive List selection through the model; on change, resolve the transcript.
    private var selectionBinding: Binding<PaneID?> {
        Binding(
            get: { model.selectedPaneID },
            set: { newID in
                guard let newID, let pane = model.panes.first(where: { $0.paneID == newID })
                else { model.selectedPaneID = newID; return }
                Task { await model.select(pane) }
            }
        )
    }
}

/// Pane row mirroring `SkillRow`'s 3-line layout: identity + status capsule + mono
/// pane-id badge (line 1), a secondary summary (line 2), identity dot + cwd (line 3).
private struct AgentPaneRow: View {
    let pane: AgentInfo

    /// Non-agent panes (plain shells) read as plumbing — dimmed name, no status capsule.
    private var isAgent: Bool { pane.agent != nil && pane.status != .unknown }

    private var summary: String {
        if let session = pane.agentSession?.value, !session.isEmpty {
            return "agent · \(pane.agent ?? "—")"
        }
        return isAgent ? "agent · \(pane.agent ?? "—")" : "plain shell · not an agent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(pane.agent ?? "shell")
                    .fontWeight(isAgent ? .medium : .regular)
                    .foregroundStyle(isAgent ? .primary : .secondary)
                if isAgent {
                    Tag(text: AgentStyle.statusLabel(pane.status),
                        color: AgentStyle.statusColor(pane.status))
                }
                Spacer()
                Text(pane.paneID.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Circle()
                    .fill(AgentStyle.identityColor(pane.agent))
                    .frame(width: 7, height: 7)
                if let cwd = pane.cwd ?? pane.foregroundCwd {
                    Text(AgentStyle.shortCwd(cwd))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text(pane.agent.map { _ in "" } ?? "idle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
