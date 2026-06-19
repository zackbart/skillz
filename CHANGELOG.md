# Changelog

All notable changes to Loadout are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [0.0.3] - 2026-06-19

### Added
- **Remote machines over SSH.** Scan another machine's skills read-only via the
  new "Machine" sidebar section (`user@host` or an `~/.ssh/config` alias). Uses
  your existing ssh keys first; if none work, prompts for a password kept only
  for the session (never stored). Remote scopes are global-only and read-only.

### Changed
- Internals: filesystem/process access now goes through a `HostIO` seam
  (`LocalHostIO`/`RemoteHostIO`, see DECISIONS D7); local behavior is unchanged.
- App icons re-compressed losslessly (pixel-identical, ~13% smaller).

## [0.0.2] - 2026-06-17

### Added
- App icon — a Fortnite-style supply-drop crate.

## [0.0.1] - 2026-06-17

### Added
- Initial release: scans every agent's global skill directories plus the
  `~/.agents/skills` canonical store, dedupes by symlink-resolved path, parses
  `SKILL.md` frontmatter, reads `.skill-lock.json` provenance, surfaces
  declared-vs-wired drift, and full-text search.
- Tag-driven release pipeline: notarized Developer ID `.dmg` published to GitHub
  Releases, with a Homebrew cask in `zackbart/homebrew-tap`.

[0.0.3]: https://github.com/zackbart/loadout/releases/tag/v0.0.3
[0.0.2]: https://github.com/zackbart/loadout/releases/tag/v0.0.2
[0.0.1]: https://github.com/zackbart/loadout/releases/tag/v0.0.1
