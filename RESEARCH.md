# Skillz — Research & Context

> Deep-research synthesis for a native macOS app that discovers, visualizes, and manages
> AI-agent **skills** across Claude Code, OpenCode, Codex, and Pi — built on the
> skills.sh / `npx skills` ecosystem. MCP integration is explicitly out of scope for now.
>
> Sources: a fan-out deep-research workflow (25 sources fetched, 123 claims, 24 verified via
> 3-vote adversarial checks) **plus ground truth captured directly from this machine**
> (`skills` CLI v1.5.10, all four agents installed). Where the two disagree, machine truth wins
> and is noted.

---

## 1. The ecosystem in one picture

skills.sh uses a **single canonical store + symlink fan-out**. There is one real copy of each
skill; every agent's skills directory holds a *relative symlink* back to it.

```
~/.agents/skills/<name>/SKILL.md     ← canonical store (REAL files)   [source of truth]
~/.agents/.skill-lock.json           ← manifest (v3): provenance, hashes, timestamps
~/.agents/plugins/                    ← plugin bundles + marketplace.json

~/.claude/skills/<name>      → ../../.agents/skills/<name>        (symlink)
~/.pi/agent/skills/<name>    → ../../../.agents/skills/<name>     (symlink)
~/.codex/skills/             → built-ins only in .system/ on this machine
~/.config/opencode/skills/   → does NOT exist on this machine (OpenCode reads ~/.agents directly)
```

**Key consequence for the app:** the same skill appears under multiple agents as symlinks to
one canonical path. **Dedupe by resolving symlinks** (`realpath` / `URL.resolvingSymlinksInPath`)
back to `~/.agents/skills/<name>`, and treat that canonical dir as the skill's identity.

---

## 2. The `npx skills` CLI (skills.sh)

- **Package:** `skills` on npm (`npx skills`), by **Vercel Labs**, MIT, **v1.5.11** (2026-06-11;
  v1.5.10 installed here at `/opt/homebrew/bin/skills`). Maintainers rauchg + quuu. Repo:
  `github.com/vercel-labs/skills`. Bins: `skills`, `add-skill`. Supports 70+ agents.
- **Commands** (verified against the local `--help`):
  - `add <owner>/<repo>` (alias `a`) — install. Flags: `-g/--global`, `-p/--project`,
    `-a/--agent <agents|*>`, `-s/--skill <names|*>`, `-l/--list`, `--copy` (copy instead of
    symlink), `-y/--yes`, `--all`, `--full-depth`.
  - `use <package>@<skill>` — generate a prompt to use a skill *without* installing.
  - `remove [skills]`, `list`/`ls`, `find [query]`, `update [skills...]` (alias `upgrade`).
  - `init [name]` — scaffold `<name>/SKILL.md`.
  - `experimental_install` — restore from `skills-lock.json`.
  - `experimental_sync` — sync skills from `node_modules` into agent dirs.
- **Machine-readable enumeration (use this!):**
  - `skills list -g --json` → array of `{ name, path, scope, agents[] }` for global skills.
  - `skills list --json` → project skills (run with project cwd).
  - ⚠️ The `agents[]` array is the CLI's **intended/declared** targets, *not* a guarantee the
    skill is symlinked into that agent on disk. On this machine several skills list
    `"Codex"`/`"OpenCode"` yet have no symlink in `~/.codex/skills`/`~/.config/opencode/skills`
    — because those agents read the canonical `~/.agents/skills` (OpenCode) or aren't fanned out.
    **The app must compute "actually active per agent" from each agent's own discovery dirs, not
    trust this field.**
- **`--copy` vs symlink:** verified in source (`src/add.ts`, `src/installer.ts`): default is
  symlink to a canonical copy; `--copy` makes independent copies; auto-falls-back to copy when
  symlinks unsupported (Windows w/o Developer Mode).

### The lock file — `~/.agents/.skill-lock.json` (v3)

Per skill: `source` (e.g. `anthropics/skills`), `sourceType` (`github`), `sourceUrl`,
`skillPath` (path to SKILL.md within the source repo), `skillFolderHash` (sha1 — drift/update
detection), `installedAt`, `updatedAt`, optional `pluginName`. Top level also has `dismissed`
flags and `lastSelectedAgents[]`. **This is the provenance + update-status layer** for the app.

---

## 3. The SKILL.md standard (Anthropic "Agent Skills")

- Open spec, canonical home **agentskills.io**; reference impl `github.com/anthropics/skills`
  (spec at `spec/agent-skills-spec.md`). Released as an open standard (~Dec 2025), multi-vendor.
- A **skill = a directory** whose required entrypoint is **`SKILL.md`** = YAML frontmatter
  between `---` markers + a Markdown body. Optional bundled resources (`scripts/`, `references/`,
  `assets/`, `examples/`) live alongside and are referenced from the body.
- **Required frontmatter:** only `name` and `description`. Constraints: `name` ≤64 chars,
  `[a-z0-9-]` only, no XML tags, cannot contain `anthropic`/`claude`; `description` non-empty,
  ≤1024 chars, no XML tags. (Good basis for an in-app linter.)
- **Three-level progressive disclosure:** L1 metadata (name/description, ~100 tok, always
  loaded), L2 SKILL.md body (loaded on trigger, target <5k tok), L3 bundled files (loaded on
  demand). Figures are guidance, not hard limits.
- **Agent-specific extension fields exist** — a robust parser must tolerate unknown keys:
  - *Claude Code* adds ~16 optional fields: `when_to_use`, `argument-hint`, `arguments`,
    `disable-model-invocation`, `user-invocable`, `allowed-tools`, `disallowed-tools`, `model`,
    `effort`, `context`, `agent`, `hooks`, `paths`, `shell`.
  - *OpenCode* recognizes: `name`, `description`, `license`, `compatibility`, `metadata`
    (string→string map); ignores unknown fields; `name` must match the directory name.

---

## 4. Per-agent on-disk map (global + project)

> Combine each agent's **native discovery dirs** with the skills-CLI **install targets** and
> scan the union; dedupe by symlink target.

### Claude Code  ✅ verified + on-disk here
- Global: `~/.claude/skills/<name>/SKILL.md`
- Project: `.claude/skills/<name>/SKILL.md`
- Plugins: `~/.claude/plugins/` — parse `installed_plugins.json`, then scan each enabled
  plugin's `skills/` subdir; plugin skills are namespaced `plugin-name:skill-name`.
- Precedence on name collision: enterprise > personal > project; plugin skills can't conflict.

### OpenCode  ✅ verified
- Global: `~/.config/opencode/skills/`, `~/.claude/skills/`, `~/.agents/skills/`
- Project (walk cwd→git root): `.opencode/skills/`, `.claude/skills/`, `.agents/skills/`
- **Reads `.claude/skills` and `.agents/skills` natively** → a skill can be visible to OpenCode
  with no OpenCode-specific symlink (explains the machine discrepancy above).
- "Active" is gated by `opencode.json` `permission` rules: `allow` / `deny` / `ask`, wildcards
  (e.g. `internal-*`), per-agent overrides. To show truly-active skills, parse & apply these.

### Codex (OpenAI Codex CLI)  ⚠️ medium confidence on native paths
- Global: `~/.codex/skills/` (built-ins under `.system/`, flagged by `.codex-system-skills.marker`;
  e.g. skill-creator, plugin-creator, skill-installer, openai-docs, imagegen).
- Project: **scan both** `.codex/skills/` (native, per secondary sources) **and** `.agents/skills/`
  (the skills-CLI install target). Primary OpenAI source: `developers.openai.com/codex/skills`.
- Caveat: on this machine no global user skills were fanned out to `~/.codex/skills` — verify
  behavior against a current Codex version before relying on it.

### Pi  ✅ verified + on-disk here
- = `github.com/badlogic/pi-mono`, npm `@earendil-works/pi-coding-agent`. Config root is
  `~/.pi/agent/`.
- Global: `~/.pi/agent/skills/` (symlinks → `~/.agents/skills/`), `~/.agents/skills/`
- Project (walk cwd→git root): `.pi/skills/`, `.agents/skills/` — **only after the project is
  trusted** (per-project trust flag). The app may want to surface trust state.

---

## 5. How the app discovers & reads skills

**Read layer (fast, offline, ground-truth):**
1. Scan the canonical `~/.agents/skills/*/SKILL.md` + each agent's discovery dirs above (and
   walk cwd→git root for project scope).
2. Parse YAML frontmatter + body; tolerate agent-specific extension fields.
3. Resolve symlinks → dedupe to canonical identity; record which agents each canonical skill is
   wired into (presence) vs. declared (`agents[]` in lock).
4. Join with `~/.agents/.skill-lock.json` for source repo, hash, install/update times.
5. Compute *active* state per agent: OpenCode permission rules, Pi project-trust, Claude
   precedence/plugin-enabled.

**Optionally** shell out to `skills list --json` as a cross-check / convenience source.

**Write layer (two-way integration):** shell out to the `skills` CLI for mutations
(`add`/`remove`/`update`/`init`), so the app stays in lockstep with ecosystem behavior instead
of reimplementing symlink fan-out. Direct file edits for editing a skill's own SKILL.md.

**Live updates:** watch the canonical store + each agent dir with FSEvents.

---

## 6. Swift / macOS implementation guidance

- **UI:** SwiftUI; `MenuBarExtra` for a menu-bar app, or a normal `WindowGroup`. (A menu-bar
  presence + a main browser window is a natural fit.)
- **YAML / frontmatter parsing:**
  - `jpsim/Yams` — de-facto Swift YAML (used by SwiftLint). Parse the frontmatter block.
  - `SwiftToolkit/frontmatter` — splits frontmatter + Markdown body in one step.
- **Directory watching:** the FSEvents C API, or a Swift wrapper — `Eonil/FSEvents`,
  `okooo5km/FSWatcher`; alternatively a `DispatchSource` file-descriptor watch per directory.
  (alexwlchan has a current write-up on watching files on macOS.)
- **Sandbox / file access:** the agent dirs (`~/.claude`, `~/.codex`, `~/.config/opencode`,
  `~/.pi`, `~/.agents`) are **outside any app container**. Two options:
  - **Non-sandboxed, Developer ID-signed, distributed outside the Mac App Store** — simplest for
    a personal/dev tool; full home-dir read access. **Recommended to start.**
  - **Sandboxed** — requires user to grant access via `NSOpenPanel` and persist
    **security-scoped bookmarks**; more friction for dotfile dirs.
- **Dev-binary-on-PATH:** per the user's convention, symlink the built app/CLI helper as
  `*-dev` into `~/.local/bin` (don't clobber any released binary).

---

## 7. Prior art (differentiate against)

- `crossoverJie/SkillDeck`, `yibie/skills-manager`, `Karanjot786/agent-skills-cli` — existing
  skill managers/CLIs/GUIs.
- skills.sh itself (`vercel-labs/skills`) is the CLI; `find` has interactive search.
- **Differentiation angle:** a *native macOS* unified view across **all four agents at once**,
  global **and** per-project, that exposes the gap between *declared* vs *actually-wired/active*
  skills (drift detection), shows provenance from the lock file, and offers two-way edit/install.
  No verified native-macOS multi-agent GUI surfaced — likely open space.

---

## 8. Open questions / to verify before/while building

1. Current OpenAI **Codex** native project/global skill discovery paths (resolve
   `.codex/skills` vs `.agents/skills`) against a live Codex version.
2. skills.sh **registry/index format** behind `find`/`add` — is there a queryable API or local
   cache to enumerate *installable* (not just installed) skills?
3. Exact `MenuBarExtra` vs window UX, and whether to ship non-sandboxed (recommended) or invest
   in security-scoped bookmarks.

---

## 9. Recommended architecture (starting point)

**Hybrid, non-sandboxed SwiftUI app:**
- **Front end:** SwiftUI (`MenuBarExtra` + main window), Developer ID-signed, non-sandboxed.
- **Read:** direct FS scan of `~/.agents/skills` + per-agent dirs (+ walk to git root for
  projects), Yams for frontmatter, symlink-resolution dedupe, join with `.skill-lock.json`,
  FSEvents for live refresh.
- **Write:** shell out to the `skills` CLI for install/remove/update; direct edits for SKILL.md.
- **Model:** one canonical `Skill` (identity = canonical path) with per-agent
  `presence`/`active` derived state and provenance from the lock.

This keeps us in lockstep with skills.sh for mutations while owning a fast, accurate read/visualize
layer — which is the actual product differentiator.

---

## npx skills — verified install algorithm (from the CLI bundle)

Source of truth: `/opt/homebrew/lib/node_modules/skills/dist/cli.mjs` (skills v1.5.10) — the
code `npx skills` actually runs. This supersedes the earlier medium-confidence Codex caveat.

```js
getCanonicalSkillsDir(global, cwd) = join(global ? ~ : cwd, ".agents", "skills")
isUniversalAgent(type)            = agents[type].skillsDir === ".agents/skills"
getAgentBaseDir(type, global, cwd):
    if isUniversalAgent(type) -> getCanonicalSkillsDir(global, cwd)   // reads .agents directly
    else (global)             -> agents[type].globalSkillsDir
    else (project)            -> join(cwd, agents[type].skillsDir)
install: write canonical to .agents/skills/<name>; for NON-universal agents create a
         RELATIVE symlink (relative(linkDir, target)) in the agent's dir. mode defaults to
         "symlink" (`--copy` makes independent copies).
```

**The canonical store is `.agents/skills`** (`~/.agents/skills` global, `<repo>/.agents/skills`
project). A "**universal agent**" (its `skillsDir === ".agents/skills"`) reads that store
directly at BOTH scopes — its `globalSkillsDir`, if defined, is unused. ~45 of the registry's
agents are universal.

### The four agents (what reads `.agents/skills`)
| Agent | project `skillsDir` | `globalSkillsDir` | Universal? | Needs own symlink? |
|---|---|---|---|---|
| Claude Code | `.claude/skills` | `~/.claude/skills` | **No** | **Yes** |
| OpenCode | `.agents/skills` | (unused) `~/.config/opencode/skills` | **Yes** | No — reads canonical |
| Codex | `.agents/skills` | (unused) `~/.codex/skills` | **Yes** | No — reads canonical |
| Pi | `.pi/skills` | `~/.pi/agent/skills` | No (CLI) — but reads `.agents` per Pi's own docs | CLI also symlinks |

**Correction:** Codex **does** read `~/.agents/skills` (it is universal). The earlier caveat that
Codex might not read `.agents` was wrong. Its `~/.codex/skills` only holds built-in `.system`
skills; user skills are reached via the canonical store.

### Implication (confirmed design)
To make a skill available everywhere: **write it to `.agents/skills`, then symlink only the
NON-universal agents** — Claude Code always; Pi as belt-and-suspenders. Universal agents
(Codex, OpenCode, + amp/cline/cursor/…) need nothing. This is exactly what `npx skills` does,
and what Skillz's drift-fix now mirrors (relative symlink into `.claude/skills`).
So at global scope, the only agent that legitimately shows drift for a canonical-present skill
is **Claude Code**.
