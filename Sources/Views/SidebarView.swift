import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List {
            // Kind switcher — Skills now, MCP reserved (DECISIONS D3).
            HStack(spacing: 6) {
                kindChip("Skills", active: true)
                kindChip("MCP", active: false, soon: true)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 8, trailing: 6))
            .listRowSeparator(.hidden)

            Section("Scope") {
                Picker("Scope", selection: $state.scopeMode) {
                    ForEach(ScopeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: state.scopeMode) { _, mode in
                    // Clear carried-over agent/source/lib/search/selection on a scope switch.
                    state.resetFilters()
                    if mode == .project && state.selectedProject == nil {
                        state.chooseProject()
                    } else {
                        state.reload()
                    }
                }

                if state.scopeMode == .project {
                    Button {
                        state.chooseProject()
                    } label: {
                        Label(state.selectedProject?.lastPathComponent ?? "Choose project…",
                              systemImage: "folder")
                    }
                    ForEach(state.recentProjects.prefix(5), id: \.self) { url in
                        Button(url.lastPathComponent) { state.setProject(url) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Library") {
                libRow(.all, "square.stack", state.skills.count)
                libRow(.drift, "exclamationmark.triangle", state.driftCount)
                libRow(.diverged, "arrow.triangle.branch", state.divergedCount)
            }

            Section("Agents") {
                ForEach(Agent.allCases) { agent in
                    selectRow(
                        selected: state.selectedAgent == agent,
                        toggle: { state.selectedAgent = state.selectedAgent == agent ? nil : agent }
                    ) {
                        Circle().fill(agent.color).frame(width: 9, height: 9)
                        Text(agent.displayName)
                        Spacer()
                        countLabel(state.count(for: agent))
                    }
                }
            }

            if !state.sources.isEmpty {
                Section("Sources") {
                    ForEach(state.sources, id: \.name) { src in
                        selectRow(
                            selected: state.selectedSource == src.name,
                            toggle: { state.selectedSource = state.selectedSource == src.name ? nil : src.name }
                        ) {
                            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                            Text(src.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            countLabel(src.count)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Pieces

    private func kindChip(_ title: String, active: Bool, soon: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).fontWeight(.semibold)
            if soon {
                Text("SOON")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(active ? Color(nsColor: .controlBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .foregroundStyle(active ? .primary : .secondary)
    }

    @ViewBuilder
    private func libRow(_ filter: LibraryFilter, _ icon: String, _ n: Int) -> some View {
        selectRow(
            selected: state.libraryFilter == filter,
            // Re-clicking the active filter toggles back to .all (so it can be cleared).
            toggle: { state.libraryFilter = (state.libraryFilter == filter ? .all : filter) }
        ) {
            Image(systemName: icon).foregroundStyle(filter == .drift && n > 0 ? Theme.drift : .secondary)
            Text(filter.label)
            Spacer()
            // Trailing fix-all affordance on the Drift row when there's drift to fix.
            if filter == .drift && n > 0 {
                Button {
                    state.fixAllDrift()
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(state.actionStatus.isRunning || state.isLoading)
                .help("Fix all drift")
            }
            countLabel(n)
        }
    }

    @ViewBuilder
    private func selectRow<Content: View>(
        selected: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle()) // make the whole row clickable, not just the text
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Theme.selection.opacity(0.12) : Color.clear)
    }

    private func countLabel(_ n: Int) -> some View {
        Text("\(n)").font(.caption.monospaced()).foregroundStyle(.secondary)
    }
}
