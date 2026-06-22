import SwiftUI
import HerdrKit

/// Screen 2: the tabs and panes/agents inside a single workspace, each with its
/// live status. Reads from the shared `SessionModel`, so status updates animate
/// in place.
struct WorkspaceDetailView: View {
    @Environment(SessionModel.self) private var session
    let workspaceID: WorkspaceID
    @State private var showingNewTab = false
    @State private var pendingClose: PendingClose?

    /// A tab or pane queued for a confirmed close (both routed through one dialog).
    private enum PendingClose: Identifiable {
        case tab(HerdrKit.Tab), pane(Pane)
        var id: String {
            switch self {
            case .tab(let t): return "t-\(t.id.rawValue)"
            case .pane(let p): return "p-\(p.id.rawValue)"
            }
        }
        var label: String {
            switch self {
            case .tab(let t): return t.label
            case .pane(let p): return p.title
            }
        }
    }

    private var workspace: Workspace? { session.workspace(workspaceID) }

    var body: some View {
        Group {
            if let workspace {
                List {
                    ForEach(workspace.tabs) { tab in
                        Section {
                            ForEach(tab.panes) { pane in
                                NavigationLink(value: pane.id) {
                                    PaneRow(pane: pane)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { pendingClose = .pane(pane) } label: {
                                        Label("Close", systemImage: "xmark")
                                    }
                                }
                            }
                        } header: {
                            SectionEyebrow(tab.label)
                                .contextMenu {
                                    Button(role: .destructive) { pendingClose = .tab(tab) } label: {
                                        Label("Close tab", systemImage: "xmark")
                                    }
                                }
                        }
                    }
                }
                .confirmationDialog(
                    "Close “\(pendingClose?.label ?? "")”?",
                    isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
                    titleVisibility: .visible,
                    presenting: pendingClose
                ) { target in
                    Button("Close", role: .destructive) {
                        Task {
                            switch target {
                            case .tab(let t): await session.closeTab(t.id)
                            case .pane(let p): await session.closePane(p.id)
                            }
                        }
                    }
                } message: { _ in
                    Text("This kills the running terminal process.")
                }
                .navigationTitle(workspace.label)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showingNewTab) {
                    NewTabSheet(workspaceID: workspaceID)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingNewTab = true } label: { Image(systemName: "plus") }
                            .tint(Theme.ink)
                            .accessibilityLabel("New tab")
                    }
                }
            } else {
                ContentUnavailableView("Workspace closed", systemImage: "xmark.rectangle",
                                       description: Text("This workspace is no longer available."))
            }
        }
    }
}

/// Sheet for `tab.create` in a fixed workspace. Label is optional; the new tab
/// appears as a section once the post-create refresh lands. Failures stay inline.
private struct NewTabSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session
    let workspaceID: WorkspaceID
    @State private var label = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label (optional)", text: $label)
                        .autocorrectionDisabled()
                } header: {
                    SectionEyebrow("tab")
                } footer: {
                    Text("Optional. Leave blank to use the server's default name.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.blocked)
                    }
                }
            }
            .navigationTitle("New tab")
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
                try await session.createTab(
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                    in: workspaceID
                )
                dismiss()
            } catch {
                self.error = String(describing: error)
                isCreating = false
            }
        }
    }
}

private struct PaneRow: View {
    let pane: Pane

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pane.isAgent ? "cpu" : "terminal")
                .font(.callout)
                .foregroundStyle(pane.isAgent ? Theme.ink : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(pane.id.rawValue)
                        .font(Theme.mono(11))
                        .foregroundStyle(.tertiary)
                    if let agent = pane.agent {
                        Text(agent)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if pane.isAgent {
                StatusTag(status: pane.status)
            }
        }
        .padding(.vertical, 4)
    }
}
