# Loadout

A native macOS app that shows every AI-agent **skill** and **MCP server** configured on your
machine — across **Claude Code, OpenCode, Codex, Cursor, and Pi** — at both the global and
project level, with tight integration to the [skills.sh](https://skills.sh) / `npx skills`
ecosystem.

Stop digging through dotfiles to see what each agent is actually loaded with.

> Clean-room, MIT-licensed. Informed by `RESEARCH.md` (verified ecosystem research) and
> by Chops (`Shpigford/chops`) as a UX reference only — no code or assets are copied.

## Install

```bash
brew install --cask zackbart/tap/loadout
```

Signed and notarized, so it opens with a normal double-click. Requires macOS 26+.

## What it does (v0.1)

- Scans each agent's global skill directories plus the `~/.agents/skills` canonical store.
- **Dedupes by canonical (symlink-resolved) path** — one skill, with badges for every agent
  that references it.
- Parses `SKILL.md` frontmatter with a real YAML parser (Yams).
- Reads `~/.agents/.skill-lock.json` for **provenance** (source repo, hash, timestamps).
- Surfaces **declared-vs-wired drift**: skills the `skills` CLI declares for an agent but that
  aren't actually symlinked on disk.
- Full-text search across name, description, and body.

## Roadmap

- Project scope (walk cwd → git root across `.claude/skills`, `.opencode/skills`,
  `.agents/skills`, `.codex/skills`, `.pi/skills`).
- Live FSEvents watching.
- Built-in `SKILL.md` editor.
- Active-state resolution (OpenCode permission rules, Pi project trust).
- Two-way mutations via the `skills` CLI (add / remove / update / init).

## Build

```bash
brew install xcodegen        # one-time
xcodegen generate            # generates Loadout.xcodeproj from project.yml
open Loadout.xcodeproj        # then ⌘R
```

The Xcode project is generated — edit `project.yml`, not the `.xcodeproj`.

## Requirements

- macOS 14+, Xcode 16+. Sole dependency: [Yams](https://github.com/jpsim/Yams) (via SPM).
- Runs non-sandboxed to read agent dotfiles in your home directory.

## Releasing

Releases are **tag-driven, and tags are the *only* thing that runs CI** — there are no
push/PR build triggers. Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds,
signs (Developer ID), notarizes, and publishes a notarized `.dmg` to GitHub Releases.

**Tags are only cut from a release-bump merge — never off a random commit:**

1. Open a "Release vX.Y.Z" PR that bumps `MARKETING_VERSION` in `project.yml`, and merge it to `main`.
2. Tag that merge commit and push the tag:

```bash
git tag v0.0.1
git push origin v0.0.1
```

CI injects the version from the tag at build time, so the `project.yml` bump is just the human
marker that makes the release commit self-describing. Release notes are auto-generated from commits.

**One-time setup** (already done): six repo secrets hold the Apple credentials —
`BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `AC_API_KEY_BASE64`, `AC_API_KEY_ID`,
`AC_API_ISSUER_ID`, `APPLE_TEAM_ID`. Regenerate them if the Developer ID cert (≈5 yr) or the
App Store Connect API key is rotated. See `DECISIONS.md` (D6).

## License

MIT — see [LICENSE](LICENSE).
