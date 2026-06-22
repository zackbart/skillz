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

            Section("Machine") {
                machineRow("Local", systemImage: "desktopcomputer", active: !state.isRemote) {
                    state.selectLocal()
                }
                ForEach(state.savedHosts, id: \.self) { target in
                    machineRow(target, systemImage: "server.rack",
                               active: state.selectedHostTarget == target) {
                        state.selectHost(target)
                    }
                    .contextMenu {
                        Button(role: .destructive) { state.removeHost(target) } label: {
                            Label("Remove host", systemImage: "trash")
                        }
                    }
                }
                Button { state.newHostInput = ""; state.showAddHost = true } label: {
                    Label("Add remote host…", systemImage: "plus")
                }
                .help("Scan a machine over SSH (user@host or an ~/.ssh/config alias)")
                if state.isRemote {
                    Button { state.reload() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Re-scan the remote machine (remote scopes don't live-update)")
                }
            }
            .selectionDisabled()

            Section("Scope") {
                Picker("Scope", selection: $state.scopeMode) {
                    ForEach(ScopeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(state.isRemote) // remote is global-only (D7)
                .onChange(of: state.scopeMode) { _, mode in
                    state.resetFilters()
                    if mode == .project {
                        state.enterProjectScope()
                    } else {
                        state.reload()
                    }
                }
            }
            .selectionDisabled()

            // Saved projects live under the Project tab only — hidden in Global scope.
            if state.scopeMode == .project {
                Section("Projects") {
                    ForEach(state.savedProjects, id: \.self) { url in
                        projectRow(url)
                    }
                    Button { state.chooseProject() } label: {
                        Label("Add project…", systemImage: "plus")
                    }
                    .help("Choose a project folder to scan and keep")
                }
                .selectionDisabled()
            }

            switch state.kind {
            case .skill:
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
                            let isLocal = src.name.hasPrefix("Local")
                            row(.source(src.name), src.name,
                                systemImage: isLocal ? "folder" : "shippingbox",
                                count: src.count, truncate: true)
                        }
                    }
                }
            case .mcp:
                Section("Library") {
                    row(.library(.all), "All", systemImage: "square.stack", count: state.mcpServers.count)
                    row(.library(.drift), "Missing", systemImage: "circle.dashed",
                        count: state.mcpDriftCount, iconTint: state.mcpDriftCount > 0 ? Theme.drift : nil)
                    row(.library(.diverged), "Diverged", systemImage: "arrow.triangle.branch",
                        count: state.mcpDivergedCount)
                }

                Section("Harnesses") {
                    ForEach(McpHarness.allCases) { harness in
                        row(.mcpHarness(harness), harness.displayName,
                            dot: harness.color, count: state.mcpCount(for: harness))
                    }
                }
            case .agents:
                // Minimal Machine section (T5b). Deeper facets (Workspaces/Library/Agents
                // from the mockup) are deferred — don't touch AppState filter machinery.
                Section("Machine") {
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer").foregroundStyle(Agent.claude.color)
                        Text("Local").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Agent.claude.color)
                    }
                    .listRowSeparator(.hidden)
                }
                .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .tint(Agent.claude.color) // Liquid Glass selection picks up the accent
        .alert("Add remote host", isPresented: $state.showAddHost) {
            TextField("user@host or ssh alias", text: $state.newHostInput)
            Button("Add") { state.addRemoteHost(state.newHostInput) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Scan this machine's skills over SSH. Tries your ssh keys first; if none work you'll be asked for a password. Read-only.")
        }
        .sheet(isPresented: Binding(
            get: { state.passwordPromptTarget != nil },
            set: { if !$0 { state.cancelPassword() } }
        )) {
            passwordPrompt
        }
    }

    /// Secure password prompt shown when key auth is refused. The password is kept only in
    /// memory for the session (never stored), so it's re-asked after relaunch.
    private var passwordPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Password for \(state.passwordPromptTarget ?? "")")
                .font(.headline)
            Text("No SSH key worked for this host. Enter a password to scan it (read-only). Kept only for this session.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $state.passwordInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { state.submitPassword() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { state.cancelPassword() }
                Button("Connect") { state.submitPassword() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.passwordInput.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// A machine row (Local or a saved remote): switch on click, check the active one.
    @ViewBuilder
    private func machineRow(_ title: String, systemImage: String,
                            active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(active ? Agent.claude.color : .secondary)
                Text(title)
                    .fontWeight(active ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Agent.claude.color)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// A saved-project row: switch on click, mark the active one, remove via context menu.
    @ViewBuilder
    private func projectRow(_ url: URL) -> some View {
        let active = state.scopeMode == .project && state.selectedProject?.path == url.path
        Button { state.setProject(url) } label: {
            HStack(spacing: 8) {
                Image(systemName: active ? "folder.fill" : "folder")
                    .foregroundStyle(active ? Agent.claude.color : .secondary)
                Text(url.lastPathComponent)
                    .fontWeight(active ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Agent.claude.color)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
        .contextMenu {
            Button(role: .destructive) { state.removeProject(url) } label: {
                Label("Remove from list", systemImage: "trash")
            }
        }
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
