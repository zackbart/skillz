import Foundation

/// Socket RPC method names, verified against a live Herdr server (protocol 14).
/// Methods are dot-namespaced; parameter keys are snake_case (`pane_id`, …).
public enum Method {
    public static let ping = "ping"

    public static let workspaceList = "workspace.list"
    public static let workspaceCreate = "workspace.create"
    public static let tabList = "tab.list"
    public static let tabCreate = "tab.create"
    public static let paneList = "pane.list"
    public static let agentList = "agent.list"

    public static let paneRead = "pane.read"
    public static let paneWaitForOutput = "pane.wait_for_output"
    public static let paneSendText = "pane.send_text"
    public static let paneSendKeys = "pane.send_keys"

    /// Open a live subscription; the server then streams events on the socket.
    public static let eventsSubscribe = "events.subscribe"
}

/// Valid `source` values for `pane.read`.
public enum PaneReadSource {
    public static let recent = "recent"
    public static let recentUnwrapped = "recent_unwrapped"
    public static let detection = "detection"
}

/// Subscription `type` strings (dot-namespaced) sent inside
/// `events.subscribe`'s `subscriptions` array.
public enum SubscriptionType {
    public static let paneAgentStatusChanged = "pane.agent_status_changed"

    /// Topology-changing subscriptions that don't need a resource id — any of
    /// these means "re-list". (Per-resource events like `pane.focused` require a
    /// `pane_id` and are intentionally omitted.)
    public static let topology = [
        "workspace.created", "workspace.updated", "workspace.closed", "workspace.renamed",
        "tab.created", "tab.closed", "tab.renamed",
        "pane.created", "pane.closed", "pane.moved", "pane.exited", "pane.agent_detected",
    ]
}

/// A subscription request, expanded into the wire `subscriptions` objects.
public enum EventSubscription: Sendable {
    /// All topology-changing events (re-list trigger).
    case topology
    /// Agent-status changes for a specific pane.
    case paneAgentStatus(PaneID)

    var jsonObjects: [JSONValue] {
        switch self {
        case .topology:
            return SubscriptionType.topology.map { .object(["type": .string($0)]) }
        case .paneAgentStatus(let pane):
            return [.object([
                "type": .string(SubscriptionType.paneAgentStatusChanged),
                "pane_id": .string(pane.rawValue),
            ])]
        }
    }
}

/// Pushed-event names (underscored) received on the wire, e.g.
/// `{"event":"pane_agent_status_changed","data":{…}}`.
public enum EventName {
    public static let paneAgentStatusChanged = "pane_agent_status_changed"

    /// Pushed events that imply the workspace/tab/pane tree changed.
    public static let topology: Set<String> = [
        "workspace_created", "workspace_updated", "workspace_closed", "workspace_renamed",
        "tab_created", "tab_closed", "tab_renamed",
        "pane_created", "pane_closed", "pane_moved", "pane_exited", "pane_agent_detected",
    ]
}
