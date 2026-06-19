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
    var loadError: String?

    /// Health of the link to the server, derived from whether RPCs are landing.
    /// Drives the toolbar indicator; `.lost` kicks off a backoff reconnect loop.
    enum LinkState { case live, lost }
    private(set) var link: LinkState = .live

    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Last status seen per pane, so we only notify on the edge *into* blocked.
    private var lastStatus: [PaneID: AgentStatus] = [:]
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
            link = .live
            // Seed the baseline from the listing so the first status *event* for a
            // pane notifies only on a real change, not the initial sync.
            for pane in workspaces.flatMap(\.panes) { lastStatus[pane.id] = pane.status }
            reconnectTask?.cancel()
            reconnectTask = nil
        } catch {
            loadError = String(describing: error)
            link = .lost
            scheduleReconnect()
        }
    }

    /// Manual "tap the dot to retry now" — just re-runs the listing.
    func reconnect() async { await refresh() }

    /// While the link is lost, keep retrying the listing on an exponential
    /// backoff (capped) until one succeeds — a successful `refresh` cancels us.
    /// ponytail: re-lists over the existing transport; an SSH session that has
    /// actually dropped is re-established by the transport on its next request.
    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            var delay: Duration = .seconds(2)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.refresh()
                if self?.link == .live { return }
                delay = min(delay * 2, .seconds(30))
            }
        }
    }

    /// Refresh a pane's display: read the scrollback and project it into a
    /// readable mobile transcript. One region — the agent's own status footer
    /// rides inline in the transcript like any other terminal output, rather
    /// than being scraped out into a separate pinned strip (the old `detection`
    /// scrape mis-classified full-screen TUI prompts as "status"). Best-effort —
    /// a failed read leaves the last snapshot in place.
    /// `isAgent` is unused now but kept so the call site needn't special-case.
    func refreshPaneDisplay(for pane: PaneID, isAgent: Bool) async {
        let recent = (try? await client.readPane(pane)) ?? outputs[pane] ?? []
        outputs[pane] = TerminalText.clean(recent)
    }

    /// Block until the pane produces new output (or the server's wait times out),
    /// so the view can re-read the instant the screen changes instead of polling
    /// on a fixed timer. Falls back to a short sleep if the wait itself fails, so
    /// a transport error can't turn the caller's loop into a hot spin.
    func awaitOutput(for pane: PaneID, source: String = PaneReadSource.recentUnwrapped) async {
        do {
            _ = try await client.waitForOutput(pane, source: source)
        } catch {
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// The raw terminal grid for a pane (uncleaned), for the Fit/Scroll modes.
    /// Returns `nil` on a read failure so the caller can keep its last grid, vs.
    /// an empty array for a genuinely blank screen.
    func rawTerminal(for pane: PaneID) async -> [String]? {
        try? await client.readRawTerminal(pane)
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

    /// Close a workspace/tab/pane, then re-list. Optimistically drops it from the
    /// tree first so the row disappears immediately; the refresh reconciles (and
    /// the `*.closed` topology event would anyway). Best-effort — a failed close
    /// is surfaced by the next refresh putting it back.
    func closeWorkspace(_ id: WorkspaceID) async {
        workspaces.removeAll { $0.id == id }
        try? await client.closeWorkspace(id)
        await refresh()
    }

    func closeTab(_ id: TabID) async {
        for w in workspaces.indices { workspaces[w].tabs.removeAll { $0.id == id } }
        try? await client.closeTab(id)
        await refresh()
    }

    func closePane(_ id: PaneID) async {
        for w in workspaces.indices {
            for t in workspaces[w].tabs.indices { workspaces[w].tabs[t].panes.removeAll { $0.id == id } }
        }
        try? await client.closePane(id)
        await refresh()
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
        let previous = lastStatus[paneID]
        lastStatus[paneID] = status
        for w in workspaces.indices {
            for t in workspaces[w].tabs.indices {
                for p in workspaces[w].tabs[t].panes.indices
                where workspaces[w].tabs[t].panes[p].id == paneID {
                    workspaces[w].tabs[t].panes[p].status = status
                    if status == .blocked, previous != .blocked {
                        let pane = workspaces[w].tabs[t].panes[p]
                        AgentNotifier.notifyBlocked(agent: pane.agent ?? pane.title,
                                                    workspace: workspaces[w].label)
                    }
                }
            }
        }
    }

    private func appendOutput(_ chunk: String, to pane: PaneID) {
        outputs[pane, default: []].append(chunk)
    }
}
