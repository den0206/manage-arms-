# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Write in **English** — this file is the source of the public GitHub Release notes.
Add entries under `## [Unreleased]` only; the release workflow cuts them into a version
heading for you (`Scripts/release-changelog.sh`). Section headings are limited to
`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`.

## [Unreleased]

### Added

- Cross-agent inventory of MCP servers, Skills, Subagents and Plugins for Claude Code,
  Cursor, Codex and Gemini CLI in a single window.
- Agent auto-detection. Agents that are not installed are shown greyed out instead of
  being hidden, so an empty cell never has to be guessed at.
- Skill and Subagent install from a pasted GitHub URL, with the fetched contents shown
  for review before anything is written to disk.
- Enable and disable for Skills and Subagents. Disabling moves the resource aside rather
  than deleting it, so it can always be turned back on.
- Update checking against the upstream repository, with a diff of `SKILL.md` shown before
  the update is applied, and a per-resource pin to stop updates entirely.
- Version pinning for MCP servers that would otherwise resolve `@latest` on every launch.
- Usage analysis from session logs, showing when each resource was last used and which
  MCP servers are running right now.
- Cross-project cleanup of `permissions.allow` entries, with filters for machine-specific
  paths and for entries duplicated across projects. The previous contents are backed up
  before anything is removed.
- Japanese and English localization.
- A prompt on launch to move ManageArms into the Applications folder when it is
  running from a mounted disk image, an external volume, or Gatekeeper's app
  translocation. Skills that were already installed stay where they are.

[Unreleased]: https://github.com/den0206/manage-arms/compare/Ver_0.0.1...HEAD
