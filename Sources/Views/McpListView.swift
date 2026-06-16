import SwiftUI

struct McpListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(state.filteredMcpServers, selection: $state.mcpSelection) { server in
            McpRow(server: server)
        }
        .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search MCP servers")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !state.mcpIssues.isEmpty { issuesBanner }
        }
        .overlay {
            if state.isLoading && state.mcpServers.isEmpty {
                ProgressView()
            } else if state.filteredMcpServers.isEmpty {
                ContentUnavailableView("No MCP servers", systemImage: "puzzlepiece.extension",
                    description: Text(emptyHint))
            }
        }
    }

    /// Unreadable configs are surfaced, never silently dropped — MCP state for those
    /// harnesses is genuinely unknown until the file is fixed by hand.
    private var issuesBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(state.mcpIssues) { issue in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    Text("\(issue.harness.displayName): \(issue.label) unreadable")
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .help(issue.reason + " · " + issue.path)
            }
        }
        .foregroundStyle(Theme.drift)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.drift.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var emptyHint: String {
        if state.scopeMode == .project && state.selectedProject == nil {
            return "Choose a project to scan its MCP configs."
        }
        return "No MCP servers found in any harness config for this scope."
    }
}

struct McpRow: View {
    let server: McpServer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(server.name).fontWeight(.medium)
                if server.definitionDiverges {
                    Tag(text: "diverged", color: Theme.drift)
                        .help("Harnesses define this server differently (a definition clash).")
                }
                if !server.conflictedHarnesses.isEmpty {
                    Tag(text: "conflict", color: Theme.drift)
                        .help("Two config origins for the same harness disagree.")
                }
                Spacer()
                if let loc = locationBadge {
                    Text(loc)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                        .help("Config location: \(loc)")
                }
                Image(systemName: server.gitStatus.systemImage)
                    .font(.caption2)
                    .foregroundStyle(server.gitStatus.color)
                    .help("\(server.gitStatus.label) — \(server.gitStatus.helpText)")
            }
            if let s = server.summary {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                ForEach(McpHarness.allCases) { harness in
                    harnessDot(harness)
                }
                if server.carriesAuth {
                    Image(systemName: "key.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("Carries auth/secret-bearing fields (preserved on edit, never shown)")
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// A dot per harness: filled = enabled, hollow = disabled, faint outline = unsupported,
    /// absent (no dot) = simply missing. Mirrors the skill side's colored-presence language.
    @ViewBuilder
    private func harnessDot(_ harness: McpHarness) -> some View {
        let st = server.state(harness)
        switch st {
        case .enabled:
            Circle().fill(harness.color).frame(width: 7, height: 7)
                .help("\(harness.displayName) · enabled")
        case .disabled:
            Circle().strokeBorder(harness.color, lineWidth: 1.5).frame(width: 7, height: 7)
                .help("\(harness.displayName) · disabled")
        case .unsupported:
            Image(systemName: "nosign").font(.system(size: 8)).foregroundStyle(.quaternary)
                .help("\(harness.displayName) · can't express this server's transport")
        case .missing:
            EmptyView()
        }
    }

    private var locationBadge: String? {
        guard case .project = server.scope, !server.logicalLocation.isEmpty else { return nil }
        return server.logicalLocation
    }
}
