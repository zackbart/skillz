import Foundation
import HerdrKit
import LocalSocketTransport
import AgentContentKit

/// Live source for the Agents axis: lists agent panes over the local Herdr socket
/// and resolves+parses a selected pane's transcript into structured blocks.
///
/// This is NOT a filesystem scan (it doesn't go through scanCache/HostIO/FileWatcher);
/// it talks to the live socket. T5a does read-once-on-appear + manual Refresh; live
/// topology subscription is deferred to T5b.
@MainActor
final class AgentsSessionModel: ObservableObject {
    @Published var panes: [AgentInfo] = []
    @Published var selectedPaneID: PaneID?
    @Published var blocks: [TranscriptBlock] = []
    /// Connection / error / empty text surfaced in the UI; nil when all is well.
    @Published var status: String?

    /// HerdrClient is an actor — its async methods are called via `await` from this
    /// @MainActor model, and results are assigned back on the main actor.
    private let client = HerdrClient(transport: LocalSocketTransport())

    /// Re-list the live panes. Errors land in `status`.
    func refresh() async {
        do {
            let listed = try await client.listAgents()
            panes = listed
            status = listed.isEmpty ? "No live agent panes." : nil
            // Drop a selection whose pane vanished.
            if let sel = selectedPaneID, !listed.contains(where: { $0.paneID == sel }) {
                selectedPaneID = nil
                blocks = []
            }
        } catch {
            status = "Couldn’t reach Herdr: \(error.localizedDescription)"
        }
    }

    /// Resolve + parse the transcript for `pane` into `blocks`.
    func select(_ pane: AgentInfo) async {
        selectedPaneID = pane.paneID
        blocks = []
        // cwd = launch cwd (the locator hashes this); fall back to foreground, then "".
        let cwd = pane.cwd ?? pane.foregroundCwd ?? ""
        let uuid = pane.agentSession?.value ?? ""
        guard !uuid.isEmpty, let url = TranscriptLocator.path(sessionUUID: uuid, cwd: cwd) else {
            status = "No transcript found for pane \(pane.paneID)."
            return
        }
        // Read + parse off the main actor — a large JSONL must not freeze the UI.
        let parsed: [TranscriptBlock]
        do {
            parsed = try await Task.detached {
                let jsonl = try String(contentsOf: url, encoding: .utf8)
                return TranscriptParser.parse(jsonl: jsonl)
            }.value
        } catch {
            guard selectedPaneID == pane.paneID else { return }
            status = "Couldn’t read transcript: \(error.localizedDescription)"
            return
        }
        // Drop the result if the user selected another pane while we loaded.
        guard selectedPaneID == pane.paneID else { return }
        blocks = parsed
        status = parsed.isEmpty ? "Transcript is empty." : nil
    }
}
