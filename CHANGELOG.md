# Changelog

All notable changes to Agent Tool are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Windows and Linux support: every feature now runs on macOS, Linux, and Windows.
- Commands for previewing and applying tool updates and refreshing the inventory.
- An "Other projects" dropdown below the User Global list: pick any project Claude Code has opened that actually holds tools to see its Skills, Subagents, MCP servers, and plugins with their descriptions and locations. Only the selected project is scanned, and the list is read-only.

### Changed

- The management core runs inside the TypeScript extension, so the VSIX no longer ships a platform binary.
- Skills and subagents are now shared through junctions and hard links on Windows, and through symbolic links on macOS and Linux.
- Replaced the extension sidebar icon with a hexagonal hub design.
- Enriched the Dashboard UI: SVG icons per tool kind (Skill/Subagent/MCP/Plugin), brand-colored glyphs, agent-dot indicators on agent tabs, and an agent-badge header card showing the active agent name and tool count.
- Tool descriptions and usage now open inline under the card that was clicked, and close on a second click; the "•••" menu is left to management actions only.
- The Dashboard now reports scan failures instead of showing an empty tool list, and all of its text is available in English and Japanese.

### Fixed

- The install button in the URL preview no longer stays on "Installing…" after the install finishes; the panel closes on success and the button returns on failure or cancellation.
- The plugin list no longer mixes in project-scoped plugins that belong to other projects; only the plugins of the project being viewed are shown.
- Scan failures in the Other projects list are reported instead of showing what looks like an empty project.
- Plugin installation now registers a supplied Marketplace before installing it; Claude no longer receives its unsupported `--marketplace` option. Plugin installation and removal show their commands for confirmation, and removal preserves the installed scope.
- Removing or disabling a project-scoped Skill or Subagent no longer deletes the user-scoped item of the same name; project files are left to the project.
- Removing a project or local MCP server now targets that registration instead of the user-wide server of the same name.
- Commands containing shell syntax are refused on Windows, where arguments would otherwise be interpreted by the command processor.
- A manually configured agent CLI path is now matched on Windows as well.

### Removed

- Deleting a tool no longer moves it to the Trash and no longer offers a 30-second undo; the confirmation dialog states that the removal is permanent.
