import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    /// Native single-selection binding: nil (deselect) falls back to All.
    private var selectionBinding: Binding<SidebarFilter?> {
        Binding(
            get: { state.sidebarFilter },
            set: { state.sidebarFilter = $0 ?? .library(.all) }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
            // Kind switcher — Skills now, MCP reserved (DECISIONS D3).
            Picker("Kind", selection: $state.kind) {
                ForEach(ResourceKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            .listRowSeparator(.hidden)
            .selectionDisabled()

            Section("Scope") {
                Picker("Scope", selection: $state.scopeMode) {
                    ForEach(ScopeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: state.scopeMode) { _, mode in
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
            .selectionDisabled()

            Section("Library") {
                row(.library(.all), "All", systemImage: "square.stack", count: state.skills.count)
                row(.library(.drift), "Drift", systemImage: "exclamationmark.triangle",
                    count: state.driftCount, iconTint: state.driftCount > 0 ? Theme.drift : nil)
                row(.library(.diverged), "Diverged", systemImage: "arrow.triangle.branch",
                    count: state.divergedCount)
            }

            Section("Agents") {
                ForEach(Agent.sidebarAgents) { agent in
                    row(.agent(agent), agent.displayName, dot: agent.color, count: state.count(for: agent))
                }
            }

            if !state.sources.isEmpty {
                Section("Sources") {
                    ForEach(state.sources, id: \.name) { src in
                        row(.source(src.name), src.name, systemImage: "shippingbox",
                            count: src.count, truncate: true)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(Agent.claude.color) // Liquid Glass selection picks up the accent
    }

    // MARK: - Rows

    /// One selectable, tagged sidebar row. Native List selection renders the macOS
    /// Liquid Glass highlight; we only supply the content + the `.tag` it selects.
    @ViewBuilder
    private func row(_ tag: SidebarFilter, _ title: String,
                     systemImage: String? = nil, dot: Color? = nil,
                     count: Int, iconTint: Color? = nil, truncate: Bool = false) -> some View {
        HStack(spacing: 8) {
            if let dot {
                Circle().fill(dot).frame(width: 9, height: 9)
            } else if let systemImage {
                Image(systemName: systemImage).foregroundStyle(iconTint ?? .secondary)
            }
            Text(title)
                .lineLimit(1)
                .truncationMode(truncate ? .middle : .tail)
            Spacer()
            Text("\(count)").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .tag(tag)
    }
}
