import Foundation

/// The semantic state Herdr reports for an agent running in a pane.
///
/// Mirrors the values documented in the socket API / `SKILL.md`:
/// `idle`, `working`, `blocked`, `done`, `unknown`.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    /// Completed and seen by the user.
    case idle
    /// Actively running.
    case working
    /// Needs input — the most urgent state.
    case blocked
    /// Completed but not yet seen.
    case done
    /// Not enough signal to classify (or not an agent).
    case unknown

    /// Ordering used when collapsing several panes into one badge: the most
    /// attention-worthy status wins (blocked > working > done > idle > unknown).
    public var priority: Int {
        switch self {
        case .blocked: return 4
        case .working: return 3
        case .done: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }

    public static func mostUrgent(_ statuses: [AgentStatus]) -> AgentStatus {
        statuses.max(by: { $0.priority < $1.priority }) ?? .unknown
    }
}
