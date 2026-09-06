# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Write in **English** — this file is the source of the public GitHub Release notes.
Add entries under `## [Unreleased]` only; the release workflow cuts them into a version
heading for you (`Scripts/release-changelog.sh`). Section headings are limited to
`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`.

## [Unreleased]

### Added

- Guided MCP and plugin installation with an explicit agent destination, registration checks,
  direct removal of existing user tools, and protected indicators for recognized bundled tools.
- Visible-window MCP process polling and scan diagnostics that distinguish failures from empty lists.
- Isolated CLI compatibility checks for Claude Code, Codex, and Gemini CLI, run on demand.

- One screen per agent for MCP servers, Skills, Subagents and Plugins across Claude Code,
  Cursor, Codex and Gemini CLI. Pick an agent in the sidebar and you see only what that
  agent carries. What you installed yourself is listed first — including plugins and MCP
  servers added through a CLI, with a note on where they are managed — while whatever
  ships with the agent is folded away.
- A home screen that leads with the add box: paste the GitHub URL of a skill and it is
  fetched for review. It also links to places to find skills and lists which agents were
  detected.
- Agent auto-detection. Agents that are not installed are shown greyed out instead of
  being hidden, so an empty cell never has to be guessed at.
- Skills and subagents that cannot be loaded — a broken symlink, a missing `SKILL.md` —
  are flagged instead of silently disappearing, so leftovers can be cleaned up.
- Project scope, on its own tab. Each agent screen has a tab for "all projects", one per
  project — `<project>/.claude/skills`, `<project>/.claude/agents`, `<project>/.mcp.json`
  and project-scoped plugins — and one for what ships with the agent. Anything installed
  both for all projects and inside individual projects is flagged on both tabs, since
  that duplication is the thing worth seeing.
- Bulk removal from projects. A project tab can remove everything it lists in one go, and a
  resource duplicated across projects can have all its project copies removed at once. The
  confirmation sheet shows the exact commands that will run. Files inside your repository
  (`<project>/.claude/skills`, `<project>/.mcp.json`) are never touched by the app — those
  commands are listed for you to copy and run yourself.
- Adoption. A skill or subagent you installed yourself can be brought under this app's
  management — it then gains the enable/disable switch and delete — as long as its files
  already sit in `~/.agents/skills`. Nothing is moved; adoption only records it and adds
  the symlink Claude Code needs.
- A "how to remove" hint for resources this app cannot delete, with the exact command for
  the agent whose screen you are on (`codex plugin remove`, `gemini mcp remove`, …) or the
  config file path for Cursor, which has no CLI — ready to copy. The command carries the
  scope of the tab you are on, so removing a project's copy never takes out the one
  installed for all projects.
- Real application icons for agents that ship a desktop app; the others keep a distinct
  symbol per agent.
- Skill and Subagent install from a pasted GitHub URL, with the fetched contents shown
  for review before anything is written to disk.
- Enable, disable and delete for Skills and Subagents. Disabling moves the resource aside;
  deleting moves it to the Trash after a confirmation, so both can be undone.
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

### Changed

- Agent names are shown without an icon in the sidebar, on Home and in the toolbar. The app no
  longer looks up desktop app icons, so the list no longer depends on which apps are installed.
- ManageArms now requires macOS 26 or later.
- Reworked the visual design across every screen. The home screen leads with the add box
  and summarises what you have installed as counts per kind, and each agent is a card you
  can click to open its screen. Rows highlight under the pointer, scope tabs slide their
  selection, counts animate when they change, a running MCP server pulses, and loading
  shows as a thin bar at the top instead of a spinner over the list. Spacing, corner radii
  and motion now come from one shared vocabulary, and every animation is disabled when
  "Reduce motion" is on.
- Toned the interface down to match the rest of macOS: no gradients, no drop shadows and
  no per-kind colour coding. Colour is now reserved for meaning — green for running, orange
  for attention, red for destructive actions.
- Simplified the home screen. The wall of chips listing every item you installed is gone —
  it could not be acted on, grows with your setup and duplicates the agent screens; the
  per-kind counts stay, plus a single line when something cannot be loaded. Where to find
  skills is now a footnote inside the add box rather than a section of its own, and the
  four agent cards are one table.
- The permissions list no longer repeats what the filter already says. The
  "machine-specific" and "duplicated" markers are hidden in the filter that selects for
  them, and `allow` is no longer tinted, so the rarer `deny` and `ask` stand out.
- Removed "adopt into ManageArms" for skills and subagents you installed yourself. You can
  now move such a file to the Trash directly, so the extra registration step is gone.
- Plugins shared through a project (`<project>/.claude/settings.json`) are no longer removed
  by the app. That file is shared through git, so ManageArms shows the command instead.

### Fixed

- Keep same-named resources separate by kind and MCP/plugin registrations separate by agent;
  pin MCP versions only for the selected agent and preserve unrelated Cursor settings.
- Refuse malformed configuration overwrites and protect bundled paths and links from deletion.
- Correct Claude MCP environment/header argument placement and Codex plugin command syntax.
- Correct the same argument placement for Gemini CLI, where the server name could be
  consumed as the value of a preceding `-e` flag.
- Messages for failed scans, additions and removals are now translated instead of always
  appearing in English.

[Unreleased]: https://github.com/den0206/manage-arms/compare/Ver_0.0.1...HEAD
