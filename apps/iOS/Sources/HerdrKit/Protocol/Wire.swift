import Foundation

// Data-transfer objects mirroring Herdr's real (flat, type-tagged) socket
// responses, verified against a live server (protocol 14). Decoded with
// `JSONValue.decodedSnake` so wire keys like `workspace_id` map to `workspaceId`.
// `HerdrClient` assembles these into the app's nested domain tree, so the rest
// of the app never sees the wire shape.

/// `workspace.list` / `workspace.get` element.
struct WorkspaceSummaryDTO: Decodable {
    let workspaceId: String
    let label: String
    let activeTabId: String?
    let agentStatus: String?
}

/// `tab.list` / `tab.get` element.
struct TabSummaryDTO: Decodable {
    let tabId: String
    let workspaceId: String
    let label: String
    let agentStatus: String?
}

/// `pane.list` / `pane.get` element.
struct PaneInfoDTO: Decodable {
    let paneId: String
    let workspaceId: String
    let tabId: String
    let cwd: String?
    let foregroundCwd: String?
    let agentStatus: String?
    let focused: Bool?
}

/// `pane.read` payload (`result.read`).
struct PaneReadDTO: Decodable {
    let text: String?
    let format: String?
}

struct WorkspaceListResult: Decodable { let workspaces: [WorkspaceSummaryDTO] }
struct TabListResult: Decodable { let tabs: [TabSummaryDTO] }
struct PaneListResult: Decodable { let panes: [PaneInfoDTO] }
struct PaneReadResult: Decodable { let read: PaneReadDTO }
