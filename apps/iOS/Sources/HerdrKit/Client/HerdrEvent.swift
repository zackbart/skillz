import Foundation

/// A decoded, domain-level event surfaced by `HerdrClient` to the UI. Raw
/// `RPCEvent`s from the socket are translated into these so views never touch
/// JSON.
public enum HerdrEvent: Sendable {
    /// An agent in a pane changed status.
    case agentStatus(pane: PaneID, status: AgentStatus)
    /// Topology changed; the client should re-list workspaces.
    case topologyChanged

    /// Translate a raw socket event, or `nil` if it isn't one we model. Event
    /// names are the underscored wire form (e.g. `pane_agent_status_changed`).
    init?(_ event: RPCEvent) {
        // Herdr's wire is dot-namespaced (`pane.agent_status_changed`), but the
        // pushed-event name form isn't pinned down in the docs and the Mock uses
        // underscores. Normalize dots→underscores so either form matches — else a
        // real server pushing the dot form drops every status/topology event and
        // the UI's status never updates live.
        switch event.method.replacingOccurrences(of: ".", with: "_") {
        case EventName.paneAgentStatusChanged:
            guard let pane = event.params["pane_id"]?.stringValue else { return nil }
            let raw = event.params["agent_status"]?.stringValue ?? event.params["status"]?.stringValue
            let status = raw.flatMap(AgentStatus.init(rawValue:)) ?? .unknown
            self = .agentStatus(pane: PaneID(pane), status: status)

        case let name where EventName.topology.contains(name):
            self = .topologyChanged

        default:
            return nil
        }
    }
}
