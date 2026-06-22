import Foundation

/// Realistic sample data so the entire UI is exercisable without a live Herdr
/// server.
public enum MockData {
    public static let workspaces: [Workspace] = [
        Workspace(
            id: "1",
            label: "herdr-ios",
            cwd: "~/code/herdr-ios",
            tabs: [
                Tab(id: "1:1", label: "agents", panes: [
                    Pane(id: "1-1", title: "claude · build UI", agent: "claude", status: .working, isFocused: true, cwd: "~/code/herdr-ios"),
                    Pane(id: "1-2", title: "codex · write tests", agent: "codex", status: .blocked, cwd: "~/code/herdr-ios"),
                ]),
                Tab(id: "1:2", label: "shell", panes: [
                    Pane(id: "1-3", title: "zsh", agent: nil, status: .unknown, cwd: "~/code/herdr-ios"),
                ]),
            ]
        ),
        Workspace(
            id: "2",
            label: "api-server",
            cwd: "~/code/api",
            tabs: [
                Tab(id: "2:1", label: "main", panes: [
                    Pane(id: "2-1", title: "claude · refactor auth", agent: "claude", status: .done, cwd: "~/code/api"),
                    Pane(id: "2-2", title: "claude · migrations", agent: "claude", status: .idle, cwd: "~/code/api"),
                    Pane(id: "2-3", title: "logs", agent: nil, status: .unknown, cwd: "~/code/api"),
                ]),
            ]
        ),
        Workspace(
            id: "3",
            label: "infra",
            cwd: "~/ops",
            tabs: [
                Tab(id: "3:1", label: "deploy", panes: [
                    Pane(id: "3-1", title: "codex · terraform plan", agent: "codex", status: .working, cwd: "~/ops"),
                ]),
            ]
        ),
    ]

    /// Canned recent scrollback per pane.
    public static let output: [PaneID: [String]] = [
        "1-1": [
            "● Building SwiftUI views…",
            "  Created WorkspaceListView.swift",
            "  Created PaneView.swift",
            "● Wiring the HerdrClient event stream",
            "  Subscribed to agent-status events",
            "▌",
        ],
        "1-2": [
            "● Writing tests for the NDJSON codec",
            "  ? Should events without an id be treated as notifications?",
            "  Waiting for your confirmation to proceed…",
        ],
        "2-1": [
            "● Refactor complete.",
            "  12 files changed, 340 insertions(+), 210 deletions(-)",
            "✓ All checks passed.",
        ],
        "3-1": [
            "● terraform plan",
            "  ~ aws_instance.app will be updated in-place",
            "  Plan: 0 to add, 1 to change, 0 to destroy.",
        ],
    ]
}
