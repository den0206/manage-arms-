# Changelog

All notable changes to Agent Tool are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-09-11

### Added

- Windows and Linux support: every feature now runs on macOS, Linux, and Windows.
- Commands for previewing and applying tool updates and refreshing the inventory.
- "Check for updates" (toolbar button and command) asks each source for its latest commit and marks the tools that have one. Without it the update badge could never appear.
- An Environment section listing which agent CLIs were found, with their version and path, and a warning when none are on PATH.
- A Status Bar badge with the number of available updates; clicking it focuses the Dashboard.
- Pin and unpin a tool to stop or resume following its updates.
- The Dashboard now watches the scanned paths while it is visible and reloads the list when they change.
- A clipboard suggestion card when a supported URL is on the clipboard.
- Skills and subagents can now be installed into the current project instead of the user profile. The install flow asks where to put it when a workspace is open; project items live in the project's own `.claude/skills` or `.claude/agents`, are tracked separately from same-named user items, and can be removed and updated from the list. Enable/disable stays user-only, since nothing is parked inside a project.
- Skill pages on Agents Directory (`agentsdirectory.dev`) can now be pasted into the URL field. The page is read once and only its schema.org JSON-LD metadata is used to find the repository. Supported sites are listed in the README and declared in one place, so adding or removing one is a single entry.
- An "Other projects" dropdown below the User Global list: pick any project Claude Code has opened that actually holds tools to see its Skills, Subagents, MCP servers, and plugins with their descriptions and locations. Only the selected project is scanned, and the list is read-only.

### Changed

- Added a color extension icon for the Extensions view and Marketplace.
- Added production installation instructions and a GitHub Actions release workflow for VSIX distribution.
- Added the Plugin installation demo to the project documentation while keeping the large GIF out of the VSIX package.
- The management core runs inside the TypeScript extension, so the VSIX no longer ships a platform binary.
- Skills and subagents are now shared through junctions and hard links on Windows, and through symbolic links on macOS and Linux.
- Replaced the extension sidebar icon with a hexagonal hub design.
- Enriched the Dashboard UI: SVG icons per tool kind (Skill/Subagent/MCP/Plugin), brand-colored glyphs, agent-dot indicators on agent tabs, and an agent-badge header card showing the active agent name and tool count.
- Read-only states (untrusted workspace, remote window) are now shown as a banner on the list instead of only failing at the moment of the operation.
- Failures now say what went wrong in the user's language before the original message (protected target, unusable name, foreign link, lock timeout).
- Applying an update now asks for confirmation, like removal does.
- Tool descriptions and usage now open inline under the card that was clicked, and close on a second click; the "•••" menu is left to management actions only.
- The Dashboard now reports scan failures instead of showing an empty tool list, and all of its text is available in English and Japanese.

### Fixed

- The install button in the URL preview no longer stays on "Installing…" after the install finishes; the panel closes on success and the button returns on failure or cancellation.
- Tool details now show the location of the item; the field was read from a property that was never filled in, so the row was always missing.
- The plugin list no longer mixes in project-scoped plugins that belong to other projects; only the plugins of the project being viewed are shown.
- Scan failures in the Other projects list are reported instead of showing what looks like an empty project.
- Plugin installation now registers a supplied Marketplace before installing it; Claude no longer receives its unsupported `--marketplace` option. Plugin installation and removal show their commands for confirmation, and removal preserves the installed scope.
- GitHub subdirectory Plugins now register the repository Marketplace root and install with its `plugin@marketplace` selector.
- Removing or disabling a project-scoped Skill or Subagent no longer deletes the user-scoped item of the same name; project files are left to the project.
- Removing a project or local MCP server now targets that registration instead of the user-wide server of the same name.
- Commands containing shell syntax are refused on Windows, where arguments would otherwise be interpreted by the command processor.
- A manually configured agent CLI path is now matched on Windows as well.

### Removed

- Unused registry fields (`usage`, `projects`, `excludedProjects`, per-agent `enabled`). Nothing read or wrote them; usage history would require scanning the agents' log directories, which the scan whitelist deliberately excludes.

- Deleting a tool no longer moves it to the Trash and no longer offers a 30-second undo; the confirmation dialog states that the removal is permanent.

