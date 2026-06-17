import Foundation

/// In-memory `HerdrTransport` that answers requests from sample data and streams
/// a trickle of live status events, so the app behaves like it's connected to a
/// busy Herdr server. Mirrors the real wire shapes (type-tagged responses,
/// `{"event":…}` envelopes) and the real one-request-per-connection model. This
/// is the default transport the app boots on.
public actor MockTransport: HerdrTransport {
    private var workspaces: [Workspace]
    private let output: [PaneID: [String]]
    private let agentPaneIDs: [PaneID]
    private let tickInterval: Duration

    public init(
        workspaces: [Workspace] = MockData.workspaces,
        output: [PaneID: [String]] = MockData.output,
        tickInterval: Duration = .seconds(3)
    ) {
        self.workspaces = workspaces
        self.output = output
        self.agentPaneIDs = workspaces.flatMap(\.agentPanes).map(\.id)
        self.tickInterval = tickInterval
    }

    public func connect() async throws {}
    public func disconnect() async {}

    public func request(_ request: RPCRequest) async throws -> RPCResponse {
        if request.method == Method.paneWaitForOutput {
            // The demo has static scrollback, so model an idle pane: wait briefly,
            // then report the server's real idle response (a `timeout` error). The
            // poll loop re-reads on its normal cadence; the live feel comes from
            // the streamed agent-status events.
            try? await Task.sleep(for: .seconds(2))
            return RPCResponse(id: request.id, result: nil,
                               error: RPCError(code: "timeout", message: "timed out waiting for output match"))
        }
        return makeResponse(for: request)
    }

    /// Persistent subscription: acks with `subscription_started`, then emits
    /// agent-status changes (the real event shape) **only for the panes the
    /// request subscribed to** via `pane.agent_status_changed`. A topology-only
    /// subscription gets the ack and no status events — mirroring the server, so
    /// tests exercise the real subscription wiring.
    public nonisolated func events(_ subscribeRequest: RPCRequest) -> AsyncStream<IncomingMessage> {
        let subscribedPanes: [PaneID] = (subscribeRequest.params["subscriptions"]?.arrayValue ?? [])
            .compactMap { sub in
                sub["type"]?.stringValue == SubscriptionType.paneAgentStatusChanged
                    ? sub["pane_id"]?.stringValue.map { PaneID($0) }
                    : nil
            }
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                continuation.yield(.response(RPCResponse(
                    id: subscribeRequest.id,
                    result: .object(["type": .string("subscription_started")]),
                    error: nil
                )))
                let interval = self.tickInterval
                let agentPanes = self.agentPaneIDs
                let targets = subscribedPanes.filter(agentPanes.contains)
                guard !targets.isEmpty else { return } // topology-only: ack, no status ticks
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { break }
                    guard let pane = targets.randomElement() else { continue }
                    let status = AgentStatus.allCases.filter { $0 != .unknown }.randomElement() ?? .working
                    continuation.yield(.event(RPCEvent(
                        method: EventName.paneAgentStatusChanged,
                        params: .object([
                            "pane_id": .string(pane.rawValue),
                            "agent_status": .string(status.rawValue),
                        ])
                    )))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A fake agent status footer (the `detection` snapshot) with ANSI color, so
    /// the demo exercises the pane's live status strip. Empty for non-agent panes.
    private func mockStatus(for pane: PaneID?) -> String {
        guard let pane, agentPaneIDs.contains(pane) else { return "" }
        let e = "\u{1B}["
        return [
            "free-screentime-app · Opus 4.8",
            "\(e)36mcontext\(e)0m ▓▓░░░░░░░░ 17%   \(e)32mgit:main*\(e)0m",
            "\(e)33m🔨 Build [heavy]\(e)0m critic:auto 1m50s",
            "  └ Build Free Screentime v1 per docs/V1_SCOPE.md…",
            "\(e)35m▶▶ bypass permissions on\(e)0m (shift+tab to cycle)",
        ].joined(separator: "\n")
    }

    /// All panes flattened, paired with their workspace/tab ids.
    private func flatPanes() -> [(workspace: Workspace, tab: Tab, pane: Pane)] {
        workspaces.flatMap { ws in ws.tabs.flatMap { tab in tab.panes.map { (ws, tab, $0) } } }
    }

    private func makeResponse(for request: RPCRequest) -> RPCResponse {
        let result: JSONValue
        switch request.method {
        case Method.workspaceList:
            result = .object(["type": .string("workspace_list"), "workspaces": .array(
                workspaces.map { ws in .object([
                    "workspace_id": .string(ws.id.rawValue),
                    "label": .string(ws.label),
                    "active_tab_id": ws.tabs.first.map { .string($0.id.rawValue) } ?? .null,
                    "agent_status": .string(ws.aggregateStatus.rawValue),
                ]) }
            )])

        case Method.tabList:
            let wsID = request.params["workspace_id"]?.stringValue
            let tabs = workspaces.first { $0.id.rawValue == wsID }?.tabs ?? []
            result = .object(["type": .string("tab_list"), "tabs": .array(
                tabs.map { tab in .object([
                    "tab_id": .string(tab.id.rawValue),
                    "workspace_id": .string(wsID ?? ""),
                    "label": .string(tab.label),
                    "agent_status": .string(AgentStatus.mostUrgent(tab.panes.map(\.status)).rawValue),
                ]) }
            )])

        case Method.paneList:
            result = .object(["type": .string("pane_list"), "panes": .array(
                flatPanes().map { entry in .object([
                    "pane_id": .string(entry.pane.id.rawValue),
                    "workspace_id": .string(entry.workspace.id.rawValue),
                    "tab_id": .string(entry.tab.id.rawValue),
                    "cwd": entry.pane.cwd.map { .string($0) } ?? .null,
                    "agent_status": .string(entry.pane.status.rawValue),
                    "focused": .bool(entry.pane.isFocused),
                ]) }
            )])

        case Method.agentList:
            // Surface agent names so the demo shows them (the real server's
            // shape is unconfirmed; the client parses this defensively).
            result = .object(["type": .string("agent_list"), "agents": .array(
                flatPanes().filter { $0.pane.isAgent }.compactMap { entry in
                    entry.pane.agent.map { name in .object([
                        "pane_id": .string(entry.pane.id.rawValue),
                        "name": .string(name),
                        "status": .string(entry.pane.status.rawValue),
                    ]) }
                }
            )])

        case Method.paneRead:
            let pane = request.params["pane_id"]?.stringValue.map { PaneID($0) }
            let text: String
            if request.params["source"]?.stringValue == PaneReadSource.detection {
                text = mockStatus(for: pane) // agent footer (ANSI-colored), else empty
            } else {
                text = (pane.flatMap { output[$0] } ?? []).joined(separator: "\n")
            }
            result = .object(["type": .string("pane_read"), "read": .object([
                "text": .string(text),
                "format": .string("text"),
            ])])

        case Method.workspaceCreate:
            let cwd = request.params["cwd"]?.stringValue
            let id = "ws-mock\(workspaces.count + 1)"
            let label = request.params["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? id
            let pane = Pane(id: PaneID("\(id)-p1"), title: "shell", isFocused: true, cwd: cwd)
            let workspace = Workspace(id: WorkspaceID(id), label: label, cwd: cwd,
                                      tabs: [Tab(id: TabID("\(id)-t1"), label: "main", panes: [pane])])
            workspaces.append(workspace)
            result = .object(["type": .string("workspace_info"), "workspace": .object([
                "workspace_id": .string(id),
                "label": .string(label),
            ])])

        case Method.tabCreate:
            let wsID = request.params["workspace_id"]?.stringValue ?? ""
            guard let idx = workspaces.firstIndex(where: { $0.id.rawValue == wsID }) else {
                return RPCResponse(id: request.id, result: nil, error: RPCError(
                    code: "not_found", message: "No such workspace: \(wsID)"))
            }
            let number = workspaces[idx].tabs.count + 1
            let tabID = "\(wsID)-t\(number)"
            let label = request.params["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "tab \(number)"
            let pane = Pane(id: PaneID("\(tabID)-p1"), title: "shell", cwd: workspaces[idx].cwd)
            workspaces[idx].tabs.append(Tab(id: TabID(tabID), label: label, panes: [pane]))
            result = .object(["type": .string("tab_info"), "tab": .object([
                "tab_id": .string(tabID),
                "workspace_id": .string(wsID),
                "label": .string(label),
            ])])

        default:
            // send_text / send_keys / ping and anything else: ack.
            result = .object(["type": .string("ok")])
        }
        return RPCResponse(id: request.id, result: result, error: nil)
    }
}
