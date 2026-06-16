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
            if let skill = state.selectedSkill {
                SkillDetailView(skill: skill)
            } else {
                ContentUnavailableView(
                    "Select a skill",
                    systemImage: "sparkles",
                    description: Text("\(state.skills.count) \(state.scopeMode.label.lowercased()) skills across your agents")
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .task { if state.skills.isEmpty { state.reload() } }
    }
}

struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Text("\(state.skills.count) skills")
            dot
            Text("\(state.driftCount) drift")
                .foregroundStyle(state.driftCount > 0 ? Theme.drift : .secondary)
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
