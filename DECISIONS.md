# SkillsSeer — Decisions

A running log of the choices that shape the app, so future work doesn't re-litigate them.

## D1 — Clean-room build, MIT licensed (not a fork of Chops)
`Shpigford/chops` does ~everything we want but is **FSL-1.1-MIT** (fair-source); a derivative
can't be relicensed to true OSS until it auto-converts to MIT (~2028). Goal is personal use **+**
open source, so we built fresh, MIT-licensed, using `RESEARCH.md` as the spec and Chops only as a
UX reference (no code/assets copied). Codex concurred.

## D2 — UI direction: Inspector (primary) + Menu-bar companion, Matrix as a view toggle
Chosen from three mockups (`~/.scratch/Dev/projects/tooling/skillsseer/ui-*.html`).
- **Inspector** is the main window: three panes — sidebar (kind switcher / library / agents / sources)
  → skill list → rich detail (provenance, drift card with one-click fix, inline SKILL.md editor).
- **Menu-bar companion** later: glanceable drop-down, drift badge, ⌘K to run/install.
- **Matrix** later: a third view-toggle for the bird's-eye declared-vs-wired drift map.
- Signature element across all: the **wired / declared / active / diverged** status system, with the
  four agent colors (Claude orange, OpenCode red, Codex green, Pi cyan) as the only chroma.

## D3 — Leave the door open for MCP servers (skills first, MCP later)
MCP management is **not** in v1, but the design must not foreclose it. Accommodations:

**Information architecture.** A top-level **kind switcher** in the sidebar: `Skills | MCP`
(shown as "SOON" in the Inspector mockup). Everything below it — agent filters, sources, the
list, the detail pane, the drift system — is reused per kind.

**Shared model seam.** Introduce an `AgentResource` abstraction that both `Skill` and a future
`McpServer` satisfy, so the list/detail/agent-chip/drift UI is kind-agnostic:
```
protocol AgentResource {            // Skill conforms now; McpServer later
    var id: String { get }          // canonical identity
    var name: String { get }
    var summary: String? { get }
    var scope: ResourceScope { get } // .global / .project(root)
    var wiredAgents: Set<Agent> { get }
    var declaredAgents: Set<Agent> { get }   // drift = declared − wired
    var provenance: SkillProvenance? { get }
}
enum ResourceKind { case skill, mcp }
```
And a provider seam so discovery differs by kind but the UI doesn't care:
```
protocol ResourceProvider { func scanGlobal() -> [AgentResource]; func scanProject(_ root: URL) -> [AgentResource] }
// SkillProvider (now)  →  McpProvider (later)
```

**Key difference to remember.** Skills are **directories** (`SKILL.md` + bundled files) discovered
by scanning the filesystem. MCP servers are **entries inside shared config files**, so discovery is
parse-config, not scan-dir, and "wired/active" means "present & enabled in that agent's config":
| Agent | MCP config (per the `mcp-sync` skill + agent docs) |
|---|---|
| Claude Code | project `.mcp.json`; user-scope in `~/.claude.json` |
| OpenCode | `opencode.json` / `~/.config/opencode/opencode.json` (`mcp` key) |
| Codex | `~/.codex/config.toml` / project `.codex/config.toml` (`mcp_servers`) |
| Pi | `~/.pi/agent/settings.json` (to verify) |

There's even an existing `mcp-sync` skill that already encodes the cross-agent source-of-truth
pattern (`MCP.md` → mirror into each config) — useful prior art / possible integration point.

**Cost now:** the kind switcher in the IA + naming the model `AgentResource` instead of hard-coding
`Skill` everywhere. We do **not** build MCP discovery, parsing, or editing yet.

## D5 — Install rule: write `.agents/skills`, symlink only `.claude` (verified)
Confirmed against each agent's own docs that 3 of 4 read the `.agents/skills` canonical store at BOTH global and project scope; Claude Code is the sole exception.

| Agent | global `~/.agents/skills` | project `<repo>/.agents/skills` | needs own symlink | source |
|---|---|---|---|---|
| OpenCode | reads | reads | no | opencode.ai/docs/skills |
| Codex | reads (`$HOME/.agents/skills`) | reads (cwd→repo root) | no | developers.openai.com/codex/skills |
| Pi | reads | reads (**after project trust**) | no (CLI also symlinks `.pi/skills`) | pi-mono docs |
| Claude Code | NO — only `~/.claude/skills` | NO — only `.claude/skills` | **YES** | code.claude.com/docs/skills |

**The rule (what `npx skills` does, minimized):**
- GLOBAL install: write real files → `~/.agents/skills/<name>/`; relative symlink `~/.claude/skills/<name>` → `../../.agents/skills/<name>`.
- PROJECT install: write real files → `<repo>/.agents/skills/<name>/`; relative symlink `<repo>/.claude/skills/<name>` → `../../.agents/skills/<name>`.
- That's it — Codex/OpenCode/Pi pick it up from `.agents/skills` directly. Only Claude needs the symlink.
- Uninstall = reverse (rm canonical dir + the `.claude` symlink).

**Caveats to surface (not blockers to the rule):**
- Pi loads PROJECT skills only after the project is **trusted** — canonical presence isn't enough until then.
- "Discovered" ≠ "active": OpenCode gates via `opencode.json` permissions (allow/deny/ask); Claude has precedence rules. The install rule controls discovery, not activation.
- For REMOTE installs (from a GitHub repo) prefer shelling out to `skills add` so the lock file + fetch are handled; for local "ensure wired everywhere" / drift-fix, do write+symlink directly.

**App consequence:** with `readsCanonicalNatively` correct, drift for a canonical-present skill collapses to a single case — "Claude Code symlink missing" — so the drift-fix is one button ("Wire into Claude Code"), already built.
