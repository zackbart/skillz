import Foundation

/// A tab groups one or more panes within a workspace.
public struct Tab: Identifiable, Codable, Hashable, Sendable {
    public let id: TabID
    public var label: String
    public var panes: [Pane]

    public init(id: TabID, label: String, panes: [Pane]) {
        self.id = id
        self.label = label
        self.panes = panes
    }
}

/// A workspace is a project container holding tabs (which hold panes).
public struct Workspace: Identifiable, Codable, Hashable, Sendable {
    public let id: WorkspaceID
    public var label: String
    public var cwd: String?
    public var tabs: [Tab]

    public init(id: WorkspaceID, label: String, cwd: String? = nil, tabs: [Tab]) {
        self.id = id
        self.label = label
        self.cwd = cwd
        self.tabs = tabs
    }

    /// All panes across every tab, flattened.
    public var panes: [Pane] { tabs.flatMap(\.panes) }

    /// Only the panes that host a recognized agent.
    public var agentPanes: [Pane] { panes.filter(\.isAgent) }

    /// A single status summarizing the workspace for the list row — the most
    /// urgent agent status present (blocked beats working beats done…).
    public var aggregateStatus: AgentStatus {
        AgentStatus.mostUrgent(agentPanes.map(\.status))
    }

    /// Count of agent panes per status, for compact badges.
    public func agentCounts() -> [AgentStatus: Int] {
        Dictionary(grouping: agentPanes, by: \.status).mapValues(\.count)
    }
}
