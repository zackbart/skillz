import SwiftUI
import HerdrKit

/// Screen 1: the list of workspaces with live aggregate agent status. Hosts the
/// `NavigationStack` and registers destinations for the drill-down screens.
struct WorkspaceListView: View {
    @Environment(SessionModel.self) private var session
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var showingNewWorkspace = false
    @State private var pendingClose: Workspace?
    @AppStorage(AgentNotifier.enabledKey) private var notify = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = session.loadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.blocked)
                }
                ForEach(session.workspaces) { workspace in
                    NavigationLink(value: workspace.id) {
                        WorkspaceRow(workspace: workspace)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingClose = workspace } label: {
                            Label("Close", systemImage: "xmark")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Close “\(pendingClose?.label ?? "")”?",
                isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
                titleVisibility: .visible,
                presenting: pendingClose
            ) { workspace in
                Button("Close workspace", role: .destructive) {
                    Task { await session.closeWorkspace(workspace.id) }
                }
            } message: { _ in
                Text("This kills every terminal and agent running in the workspace.")
            }
            .navigationDestination(for: WorkspaceID.self) { id in
                WorkspaceDetailView(workspaceID: id)
            }
            .navigationDestination(for: PaneID.self) { id in
                PaneView(paneID: id)
            }
            .refreshable { await session.refresh() }
            .overlay {
                if session.workspaces.isEmpty && session.loadError == nil {
                    ContentUnavailableView("No workspaces", systemImage: "rectangle.3.group",
                                           description: Text("Tap + to create your first workspace."))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingNewWorkspace) {
                NewWorkspaceSheet { newID in path.append(newID) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await app.disconnect() } } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .tint(Theme.ink)
                    .accessibilityLabel("Disconnect")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { toggleNotify() } label: {
                        Image(systemName: notify ? "bell.fill" : "bell.slash")
                    }
                    .tint(notify ? Theme.prompt : Theme.ink)
                    .accessibilityLabel(notify ? "Blocked-agent alerts on" : "Blocked-agent alerts off")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewWorkspace = true } label: { Image(systemName: "plus") }
                        .tint(Theme.ink)
                        .accessibilityLabel("New workspace")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Workspaces").font(.headline)
                        Button { Task { await session.reconnect() } } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(session.link == .live ? Theme.idle : Theme.blocked)
                                    .frame(width: 6, height: 6)
                                Text(session.link == .live ? session.label : "Reconnecting…")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(session.link == .live)
                        .accessibilityLabel(session.link == .live
                            ? "Connected to \(session.label)" : "Connection lost. Tap to retry.")
                    }
                }
            }
        }
        .tint(Theme.prompt)
    }

    /// Flip the alerts pref. Turning on requests system authorization and only
    /// sticks if granted, so the toggle never lies about whether alerts can fire.
    private func toggleNotify() {
        if notify { notify = false; return }
        Task { notify = await AgentNotifier.requestAuthorization() }
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace

    private var agentCount: Int { workspace.agentPanes.count }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(workspace.aggregateStatus.color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspace.label)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(agentCount) agent\(agentCount == 1 ? "" : "s")")
                        .font(Theme.mono(11))
                        .foregroundStyle(.tertiary)
                }
                if let cwd = workspace.cwd {
                    Text(cwd)
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                StatusSummary(counts: workspace.agentCounts())
            }
        }
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sheet for `workspace.create`. Label and cwd are both optional (the server
/// defaults them); on success it dismisses and hands the new id back so the list
/// can navigate into it. Failures stay inline so the user can fix and retry.
private struct NewWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session
    @State private var label = ""
    @State private var cwd = ""
    @State private var isCreating = false
    @State private var error: String?
    let onCreated: (WorkspaceID) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label (optional)", text: $label)
                        .autocorrectionDisabled()
                    TextField("Working directory (optional)", text: $cwd)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    SectionEyebrow("workspace")
                } footer: {
                    Text("Both optional. The working directory is a path on the Herdr host (e.g. ~/project); leave blank to use the server's default.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.blocked)
                    }
                }
            }
            .navigationTitle("New workspace")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isCreating)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create") { create() }
                    }
                }
            }
        }
        .tint(Theme.prompt)
    }

    private func create() {
        isCreating = true
        error = nil
        Task {
            do {
                let id = try await session.createWorkspace(
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                    cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                dismiss()
                if let id { onCreated(id) }
            } catch {
                self.error = String(describing: error)
                isCreating = false
            }
        }
    }
}
