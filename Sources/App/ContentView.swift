import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 232)
        } content: {
            SkillListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 350)
        } detail: {
            if state.kind == .skill {
                if let skill = state.selectedSkill {
                    SkillDetailView(skill: skill)
                } else {
                    ContentUnavailableView(
                        "Select a skill",
                        systemImage: "sparkles",
                        description: Text("\(state.skills.count) \(state.scopeMode.label.lowercased()) skills across your agents")
                    )
                }
            } else {
                if let server = state.selectedMcpServer {
                    McpDetailView(server: server)
                } else {
                    ContentUnavailableView(
                        "Select an MCP server",
                        systemImage: "puzzlepiece.extension",
                        description: Text("\(state.mcpServers.count) \(state.scopeMode.label.lowercased()) MCP servers across your harnesses")
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .task { if state.skills.isEmpty { state.reload() } }
        // App-wide surfacing of any mutation failure (no longer swallowed by try?).
        .alert("Action failed",
               isPresented: Binding(get: { state.lastError != nil },
                                    set: { if !$0 { state.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            if state.kind == .skill {
                Text("\(state.skills.count) skills")
                dot
                Text("\(state.driftCount) drift")
                    .foregroundStyle(state.driftCount > 0 ? Theme.drift : .secondary)
            } else {
                Text("\(state.mcpServers.count) servers")
                dot
                Text("\(state.mcpDivergedCount) diverged")
                    .foregroundStyle(state.mcpDivergedCount > 0 ? Theme.drift : .secondary)
                if !state.mcpIssues.isEmpty {
                    dot
                    Label("\(state.mcpIssues.count) unreadable",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.drift)
                }
            }
            dot
            Text(state.scopeMode == .global ? "Global" : (state.selectedProject?.lastPathComponent ?? "Project"))
            Spacer()
            if !state.cliAvailable {
                Label("no skills CLI", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.drift)
            }
            Label(state.gitAvailable ? "watching" : "git off",
                  systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(state.gitAvailable ? Color(hex: 0x2BA160) : .secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }
}
