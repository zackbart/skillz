import Foundation
import HerdrKit

/// The single source of truth for a connected Herdr session. Holds the live
/// workspace tree and per-pane scrollback, applies server-pushed events, and
/// exposes the actions the screens need. Injected into the view hierarchy via
/// SwiftUI's environment.
@MainActor
@Observable
final class SessionModel {
    let client: HerdrClient
    let label: String

    var workspaces: [Workspace] = []
    /// Scrollback lines per pane, populated by `loadOutput` and grown by events.
    var outputs: [PaneID: [String]] = [:]
    /// The agent status-region snapshot per pane (raw, ANSI-bearing lines from
    /// `pane.read` `detection`), refreshed by polling while a pane is open.
    var statusLines: [PaneID: [String]] = [:]
    var loadError: String?

    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var subscribedTopology = false
    private var subscribedPanes: Set<PaneID> = []

    init(client: HerdrClient, label: String) {
        self.client = client
        self.label = label
    }

    /// Load the initial workspace list, begin observing live events, and
    /// subscribe to topology + per-agent-pane status changes.
    func start() async {
        await refresh()
        observeEvents()
        await syncSubscriptions()
    }

    /// Subscribe to topology once, plus agent-status for any agent panes we
    /// haven't subscribed to yet. Safe to call after each refresh.
    private func syncSubscriptions() async {
        var subscriptions: [EventSubscription] = []
        let needsTopology = !subscribedTopology
        if needsTopology { subscriptions.append(.topology) }
        let agentPanes = Set(workspaces.flatMap(\.panes).filter(\.isAgent).map(\.id))
        let fresh = agentPanes.subtracting(subscribedPanes)
        subscriptions += fresh.map { .paneAgentStatus($0) }
        guard !subscriptions.isEmpty else { return }
        do {
            try await client.subscribe(subscriptions)
            // Mark as subscribed only on success → a failure is retried on the
            // next refresh instead of being silently lost.
            if needsTopology { subscribedTopology = true }
            subscribedPanes.formUnion(fresh)
        } catch {
            // Leave unmarked; the next refresh will retry.
        }
    }

    func refresh() async {
        do {
            workspaces = try await client.listWorkspaces()
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    /// Refresh a pane's display in one pass: read the scrollback and (for agents)
    /// the status footer concurrently, project both into a readable mobile
    /// transcript, and drop the footer from the scrollback so it isn't shown
    /// twice. Best-effort — a failed read leaves the last snapshot in place.
    func refreshPaneDisplay(for pane: PaneID, isAgent: Bool) async {
        async let recentTask = client.readPane(pane)
        async let detectionTask: [String] = isAgent ? client.readAgentStatus(pane) : []
        let recent = (try? await recentTask) ?? outputs[pane] ?? []
        let detection = (try? await detectionTask) ?? []

        if isAgent { statusLines[pane] = TerminalText.clean(detection) }
        let deduped = TerminalText.removeOverlap(scrollback: recent, footer: detection)
        outputs[pane] = TerminalText.clean(deduped)
    }

    /// Block until the pane produces new output (or the server's wait times out),
    /// so the view can re-read the instant the screen changes instead of polling
    /// on a fixed timer. Falls back to a short sleep if the wait itself fails, so
    /// a transport error can't turn the caller's loop into a hot spin.
    func awaitOutput(for pane: PaneID) async {
        do {
            _ = try await client.waitForOutput(pane)
        } catch {
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// The exact terminal grid for a pane, for the Raw inspector (uncleaned).
    func rawTerminal(for pane: PaneID) async -> [String] {
        (try? await client.readRawTerminal(pane)) ?? []
    }

    /// Submit a line of input (text + Enter), echoing it optimistically.
    func submit(_ text: String, to pane: PaneID) async {
        guard !text.isEmpty else { return }
        appendOutput("❯ \(text)", to: pane)
        try? await client.submitLine(text, to: pane)
    }

    func sendKeys(_ keys: String, to pane: PaneID) async {
        try? await client.sendKeys(keys, to: pane)
    }

    /// Create a workspace, then re-list so the new one is in `workspaces` before
    /// the caller navigates into it. Returns its id when the server reports one.
    /// Throws on failure so the presenting sheet can surface it inline (errors
    /// here are transient and sheet-local, unlike the persistent `loadError`).
    func createWorkspace(label: String?, cwd: String?) async throws -> WorkspaceID? {
        let id = try await client.createWorkspace(label: label, cwd: cwd)
        await refresh()
        await syncSubscriptions()
        return id
    }

    /// Create a tab in `workspace`, then re-list so it appears in the detail view.
    @discardableResult
    func createTab(label: String?, in workspace: WorkspaceID) async throws -> TabID? {
        let id = try await client.createTab(label: label, in: workspace)
        await refresh()
        await syncSubscriptions()
        return id
    }

    // MARK: Lookups

    func workspace(_ id: WorkspaceID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    func pane(_ id: PaneID) -> Pane? {
        workspaces.flatMap(\.panes).first { $0.id == id }
    }

    // MARK: Event handling

    private func observeEvents() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let stream = await self?.client.eventStream else { return }
            for await event in stream {
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: HerdrEvent) {
        switch event {
        case .agentStatus(let pane, let status):
            updateStatus(status, for: pane)
        case .topologyChanged:
            scheduleRefresh()
        }
    }

    /// Coalesce bursty topology events (a workspace close emits tab + pane
    /// closes too) into a single debounced re-list + re-subscribe.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refresh()
            await self?.syncSubscriptions()
        }
    }

    private func updateStatus(_ status: AgentStatus, for paneID: PaneID) {
        for w in workspaces.indices {
            for t in workspaces[w].tabs.indices {
                for p in workspaces[w].tabs[t].panes.indices
                where workspaces[w].tabs[t].panes[p].id == paneID {
                    workspaces[w].tabs[t].panes[p].status = status
                }
            }
        }
    }

    private func appendOutput(_ chunk: String, to pane: PaneID) {
        outputs[pane, default: []].append(chunk)
    }
}
