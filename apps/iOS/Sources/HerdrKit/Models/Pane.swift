import Foundation

/// A pane is a real terminal process inside a tab. It may host an identified
/// agent (e.g. Claude Code, Codex), in which case `agent` carries its name and
/// `status` reflects the agent's live state.
public struct Pane: Identifiable, Codable, Hashable, Sendable {
    public let id: PaneID
    /// Human-facing title (process / command / agent label).
    public var title: String
    /// Name of the detected agent, e.g. `"claude"`. `nil` when the pane is a
    /// plain shell rather than a recognized agent.
    public var agent: String?
    public var status: AgentStatus
    /// Whether this pane currently holds focus within its tab.
    public var isFocused: Bool
    public var cwd: String?
    /// True when this pane hosts a recognized agent. Stored (not `agent != nil`)
    /// because the real API can report an agent status for a pane before its
    /// name is known — we still want the UI to treat it as an agent pane.
    public var isAgent: Bool

    public init(
        id: PaneID,
        title: String,
        agent: String? = nil,
        status: AgentStatus = .unknown,
        isFocused: Bool = false,
        cwd: String? = nil,
        isAgent: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.status = status
        self.isFocused = isFocused
        self.cwd = cwd
        self.isAgent = isAgent ?? (agent != nil)
    }
}
