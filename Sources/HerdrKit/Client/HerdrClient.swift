import Foundation

/// High-level, typed API over a `HerdrTransport`.
///
/// Responsibilities:
///  - generate request ids and correlate replies to the awaiting caller,
///  - demultiplex server-pushed events into a single `events` stream the UI
///    can observe for live status/output updates,
///  - expose ergonomic async methods (`listWorkspaces`, `readPane`, …).
///
/// It is an `actor`, so all id/continuation bookkeeping is serialized without
/// locks.
public actor HerdrClient {
    private let transport: HerdrTransport

    private var nextID = 0
    private var subscriptionTasks: [Task<Void, Never>] = []

    private let events: AsyncStream<HerdrEvent>
    private let eventsContinuation: AsyncStream<HerdrEvent>.Continuation

    public init(transport: HerdrTransport) {
        self.transport = transport
        var continuation: AsyncStream<HerdrEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventsContinuation = continuation
    }

    /// Live stream of domain events. Observe this to react to status/output
    /// changes. Multiple awaits share one underlying stream.
    public var eventStream: AsyncStream<HerdrEvent> { events }

    // MARK: Lifecycle

    public func connect() async throws {
        try await transport.connect()
        // No request/event channels yet — RPCs open one channel each, and
        // `subscribe(_:)` opens the persistent event channel.
    }

    public func disconnect() async {
        for task in subscriptionTasks { task.cancel() }
        subscriptionTasks.removeAll()
        await transport.disconnect()
        eventsContinuation.finish()
    }

    // MARK: Typed API

    public func ping() async throws {
        _ = try await call(Method.ping)
    }

    /// Build the nested workspace tree from Herdr's flat, granular endpoints:
    /// `workspace.list` + a single global `pane.list` + `tab.list` per workspace
    /// + best-effort `agent.list` (for agent names). `HerdrClient` is the
    /// anti-corruption layer; the UI keeps seeing a nested tree.
    public func listWorkspaces() async throws -> [Workspace] {
        let wsList = try await call(Method.workspaceList).decodedSnake(WorkspaceListResult.self)
        let paneList = try await call(Method.paneList).decodedSnake(PaneListResult.self)
        let agentNames = await agentNameMap()
        let panesByTab = Dictionary(grouping: paneList.panes, by: \.tabId)

        var workspaces: [Workspace] = []
        for ws in wsList.workspaces {
            let tabList = try await call(
                Method.tabList, .object(["workspace_id": .string(ws.workspaceId)])
            ).decodedSnake(TabListResult.self)

            let tabs = tabList.tabs.map { tab in
                Tab(
                    id: TabID(tab.tabId),
                    label: tab.label,
                    panes: (panesByTab[tab.tabId] ?? []).map { makePane($0, agentNames) }
                )
            }
            let allPanes = tabs.flatMap(\.panes)
            let cwd = (allPanes.first(where: \.isFocused) ?? allPanes.first)?.cwd
            workspaces.append(Workspace(id: WorkspaceID(ws.workspaceId), label: ws.label, cwd: cwd, tabs: tabs))
        }
        return workspaces
    }

    /// Read a pane's scrollback as logical lines (`recent_unwrapped`, so the
    /// server's terminal-width soft-wrapping isn't baked in — the right source to
    /// re-wrap for a narrow screen). `TerminalText.clean` makes it mobile-ready.
    public func readPane(_ pane: PaneID, lines: Int = 200) async throws -> [String] {
        try await readLines(pane, source: PaneReadSource.recentUnwrapped, lines: lines,
                            format: PaneReadFormat.ansi, stripAnsi: false)
    }

    /// Read the exact terminal grid (`recent`, hard-wrapped to the server width).
    /// Backs the Fit/Scroll grid modes; the Reader mode uses `readPane`. ANSI is
    /// kept so the UI can render fg/bg/inverse cells (e.g. an agent's logo).
    public func readRawTerminal(_ pane: PaneID, lines: Int = 500) async throws -> [String] {
        try await readLines(pane, source: PaneReadSource.recent, lines: lines,
                            format: PaneReadFormat.ansi, stripAnsi: false)
    }

    private func readLines(_ pane: PaneID, source: String, lines: Int?,
                           format: String? = nil, stripAnsi: Bool? = nil) async throws -> [String] {
        var params: [String: JSONValue] = [
            "pane_id": .string(pane.rawValue),
            "source": .string(source),
        ]
        if let lines { params["lines"] = .int(lines) }
        if let format { params["format"] = .string(format) }
        if let stripAnsi { params["strip_ansi"] = .bool(stripAnsi) }
        let result = try await call(Method.paneRead, .object(params))
        guard let text = try result.decodedSnake(PaneReadResult.self).read.text else { return [] }
        var split = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Grid rows arrive CRLF-terminated when ANSI isn't stripped — drop the CR
        // so it doesn't leak into rendering or inflate the fit-mode width count.
        for i in split.indices where split[i].hasSuffix("\r") { split[i].removeLast() }
        if split.last == "" { split.removeLast() } // drop the artifact of a trailing newline
        return split
    }

    /// Block until the pane emits **new** output, or `timeoutMS` elapses. Returns
    /// `true` if output arrived, `false` on a clean timeout. This is the
    /// event-driven alternative to fixed-interval polling: it holds one channel
    /// open and returns the instant the screen changes, staying quiet while idle.
    ///
    /// `match` is a regex that matches any single character (incl. newlines), so
    /// any new output satisfies it — `pane.wait_for_output` is otherwise a
    /// targeted wait (substring/regex). A timeout comes back as an RPC error with
    /// code `timeout`, which we treat as a normal "nothing happened" result.
    @discardableResult
    public func waitForOutput(
        _ pane: PaneID,
        source: String = PaneReadSource.recentUnwrapped,
        timeoutMS: Int = 15_000
    ) async throws -> Bool {
        do {
            _ = try await call(Method.paneWaitForOutput, .object([
                "pane_id": .string(pane.rawValue),
                "source": .string(source),
                "timeout_ms": .int(timeoutMS),
                "match": .object(["type": .string("regex"), "value": .string("(?s:.)")]),
            ]))
            return true
        } catch HerdrError.rpc(let error) where error.code == "timeout" {
            return false
        }
    }

    /// Send literal text to a pane without a trailing newline.
    public func sendText(_ text: String, to pane: PaneID) async throws {
        _ = try await call(Method.paneSendText, .object([
            "pane_id": .string(pane.rawValue),
            "text": .string(text),
        ]))
    }

    /// Send one or more named key presses to a pane. Key names use Herdr's
    /// syntax: plain names (`Enter`, `Esc`, `Tab`, `Up`…) and modifier combos
    /// with `+` (`ctrl+b`, `ctrl+c`). The wire field is a sequence.
    public func sendKeys(_ keys: String..., to pane: PaneID) async throws {
        _ = try await call(Method.paneSendKeys, .object([
            "pane_id": .string(pane.rawValue),
            "keys": .array(keys.map(JSONValue.string)),
        ]))
    }

    /// Convenience: submit a line of input (text + Enter), as the pane view does.
    public func submitLine(_ text: String, to pane: PaneID) async throws {
        try await sendText(text, to: pane)
        try await sendKeys("Enter", to: pane)
    }

    /// Create a new workspace. Both params are optional — the server fills in
    /// defaults (an omitted `cwd` uses the server's working directory). Returns
    /// the new workspace's id when the server reports one, so the caller can
    /// navigate straight into it; `nil` if the result omits it (the tree still
    /// re-lists, both via the explicit refresh and the `workspace_created` event).
    public func createWorkspace(label: String? = nil, cwd: String? = nil) async throws -> WorkspaceID? {
        var params: [String: JSONValue] = [:]
        if let label, !label.isEmpty { params["label"] = .string(label) }
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        let result = try await call(Method.workspaceCreate, .object(params))
        return Self.extractID(result, idKey: "workspace_id", nested: "workspace").map { WorkspaceID($0) }
    }

    /// Create a new tab in `workspace`. `label` is optional. Returns the new
    /// tab's id when reported (same lenient parse / re-list contract as above).
    public func createTab(label: String? = nil, in workspace: WorkspaceID) async throws -> TabID? {
        var params: [String: JSONValue] = ["workspace_id": .string(workspace.rawValue)]
        if let label, !label.isEmpty { params["label"] = .string(label) }
        let result = try await call(Method.tabCreate, .object(params))
        return Self.extractID(result, idKey: "tab_id", nested: "tab").map { TabID($0) }
    }

    /// Pull a created resource's id out of a create result, tolerating the shapes
    /// Herdr might use: a top-level `<thing>_id`, a nested `{"<thing>":{…}}`
    /// (mirroring `*.get`'s `{"type":"pane_info","pane":{…}}`), or a bare `id`.
    /// Create's result body isn't pinned down in the docs, so parse defensively.
    private static func extractID(_ result: JSONValue, idKey: String, nested: String) -> String? {
        result[idKey]?.stringValue
            ?? result[nested]?[idKey]?.stringValue
            ?? result["id"]?.stringValue
            ?? result[nested]?["id"]?.stringValue
    }

    /// Open live subscriptions on a persistent event channel. Each call opens
    /// its own channel (Herdr streams events per subscription connection); the
    /// pushed events are funnelled into `eventStream`.
    public func subscribe(_ subscriptions: [EventSubscription]) async throws {
        let objects = subscriptions.flatMap(\.jsonObjects)
        guard !objects.isEmpty else { return }
        nextID += 1
        let request = RPCRequest(
            id: "sub_\(nextID)",
            method: Method.eventsSubscribe,
            params: .object(["subscriptions": .array(objects)])
        )
        let stream = transport.events(request)
        // Confirm the channel opened (first message = the `subscription_started`
        // ack) before returning, so a failed subscription throws and the caller
        // can retry — then keep funnelling events in the background.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = Task { [weak self] in
                var opened = false
                for await message in stream {
                    if !opened {
                        opened = true
                        if case .response(let response) = message, let error = response.error {
                            continuation.resume(throwing: HerdrError.rpc(error))
                            return
                        }
                        continuation.resume()
                    }
                    if case .event(let raw) = message, let domain = HerdrEvent(raw) {
                        await self?.emit(domain)
                    }
                }
                if !opened {
                    continuation.resume(throwing: HerdrError.connectionFailed(
                        "The event subscription closed before it started."))
                }
            }
            subscriptionTasks.append(task)
        }
    }

    private func emit(_ event: HerdrEvent) { eventsContinuation.yield(event) }

    // MARK: Assembly helpers

    /// Best-effort `pane_id → agent name` map. `agent.list`'s shape isn't pinned
    /// down (it's empty unless agents run), so parse defensively and tolerate any
    /// shape — names are enrichment, not correctness.
    private func agentNameMap() async -> [String: String] {
        guard let result = try? await call(Method.agentList),
              let agents = result["agents"]?.arrayValue else { return [:] }
        var map: [String: String] = [:]
        for agent in agents {
            guard let paneID = agent["pane_id"]?.stringValue else { continue }
            let name = agent["name"]?.stringValue ?? agent["agent"]?.stringValue
                ?? agent["kind"]?.stringValue ?? agent["title"]?.stringValue
            if let name { map[paneID] = name }
        }
        return map
    }

    private func makePane(_ dto: PaneInfoDTO, _ agentNames: [String: String]) -> Pane {
        let status = dto.agentStatus.flatMap(AgentStatus.init(rawValue:)) ?? .unknown
        let name = agentNames[dto.paneId]
        let isAgent = name != nil || status != .unknown
        let title = name ?? "shell"
        return Pane(
            id: PaneID(dto.paneId),
            title: title,
            agent: name,
            status: status,
            isFocused: dto.focused ?? false,
            cwd: dto.foregroundCwd ?? dto.cwd,
            isAgent: isAgent
        )
    }

    // MARK: Request plumbing

    private func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        nextID += 1
        let request = RPCRequest(id: "req_\(nextID)", method: method, params: params)
        let response = try await transport.request(request)
        if let error = response.error { throw HerdrError.rpc(error) }
        return response.result ?? .null
    }
}
