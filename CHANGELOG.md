# Changelog

All notable changes to Loadout are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

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

[0.0.2]: https://github.com/zackbart/loadout/releases/tag/v0.0.2
[0.0.1]: https://github.com/zackbart/loadout/releases/tag/v0.0.1
