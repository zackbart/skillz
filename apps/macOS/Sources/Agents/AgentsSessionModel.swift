import Foundation
import HerdrKit
import LocalSocketTransport
import AgentContentKit

/// Live source for the Agents axis: lists agent panes over the local Herdr socket
/// and resolves+parses a selected pane's transcript into structured blocks.
///
/// Pane topology comes from the live socket; the transcript is a JSONL file we
/// re-parse whenever FSEvents reports its directory changed, so the agent's turns
/// stream into the view without a manual Refresh. (Topology still needs Refresh —
/// live topology subscription is deferred.)
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

    /// The selected pane's transcript file + a watcher on its directory. The watcher
    /// re-parses the file on change so new turns appear live.
    private var transcriptURL: URL?
    private var watcher: FileWatcher?

    /// Re-list the live panes. Errors land in `status`.
    func refresh() async {
        do {
            let listed = try await client.listAgents()
            panes = listed
            status = listed.isEmpty ? "No live agent panes." : nil
            // Drop a selection whose pane vanished; otherwise reload its transcript
            // so Refresh actually shows new content (no live subscription yet).
            if let sel = selectedPaneID {
                if let pane = listed.first(where: { $0.paneID == sel }) {
                    await select(pane)
                } else {
                    selectedPaneID = nil
                    blocks = []
                    stopWatching()
                }
            }
        } catch {
            status = "Couldn’t reach Herdr: \(error.localizedDescription)"
        }
    }

    /// Resolve the transcript for `pane`, parse it, and start watching it live.
    func select(_ pane: AgentInfo) async {
        let switching = selectedPaneID != pane.paneID
        selectedPaneID = pane.paneID
        if switching { blocks = [] }   // clear only when changing panes, not on re-parse
        // cwd = launch cwd (the locator hashes this); fall back to foreground, then "".
        let cwd = pane.cwd ?? pane.foregroundCwd ?? ""
        let uuid = pane.agentSession?.value ?? ""
        guard !uuid.isEmpty, let url = TranscriptLocator.path(sessionUUID: uuid, cwd: cwd) else {
            transcriptURL = nil
            stopWatching()
            status = "No transcript found for pane \(pane.paneID)."
            return
        }
        transcriptURL = url
        await reparse()
        // Watch the transcript's directory; FSEvents fires on append, we re-parse.
        // ponytail: re-parses the whole file per change — fine until transcripts get huge.
        let watcher = FileWatcher { [weak self] in
            Task { await self?.reparse() }
        }
        watcher.start(paths: [url.deletingLastPathComponent().path])
        self.watcher = watcher
    }

    /// Read + parse `transcriptURL` off the main actor and publish it. Used on
    /// select and on every FSEvents change. No-op if the parse is unchanged.
    private func reparse() async {
        guard let url = transcriptURL else { return }
        let owner = selectedPaneID
        let parsed: [TranscriptBlock]
        do {
            parsed = try await Task.detached {
                let jsonl = try String(contentsOf: url, encoding: .utf8)
                return TranscriptParser.parse(jsonl: jsonl)
            }.value
        } catch {
            guard selectedPaneID == owner else { return }
            status = "Couldn’t read transcript: \(error.localizedDescription)"
            return
        }
        // Drop the result if the selection changed while we loaded.
        guard selectedPaneID == owner else { return }
        guard parsed != blocks else { return }   // skip needless republish/scroll
        blocks = parsed
        status = parsed.isEmpty ? "Transcript is empty." : nil
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        transcriptURL = nil
    }

    /// Submit a follow-up line (text + Enter) to the selected pane. The live
    /// watcher surfaces the resulting turns — no manual reload needed.
    func submit(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = selectedPaneID else { return }
        do {
            try await client.submitLine(trimmed, to: id)
        } catch {
            status = "Couldn’t send: \(error.localizedDescription)"
        }
    }
}
