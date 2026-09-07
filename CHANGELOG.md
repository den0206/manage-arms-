# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Write in **English** — this file is the source of the public GitHub Release notes.
Add entries under `## [Unreleased]` only; the release workflow cuts them into a version
heading for you (`Scripts/release-changelog.sh`). Section headings are limited to
`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`.

## [Unreleased]

### Security

- A skill or subagent fetched from GitHub could no longer be written outside the directories
  ManageArms manages. The `name` in a `SKILL.md` front matter is written by whoever publishes
  the repository, and it was used as a path component without checking, so a name containing
  `../` escaped the managed store. Names are now validated before anything is created.

### Added

- Settings lists every scanned project with an Exclude button; excluded projects are kept in
  `registry.json` and come back with Restore.

### Fixed

- Your home folder and the filesystem root are no longer treated as projects. Starting an agent
  from your home directory once listed it as a project and pulled every other project's skills
  into that one tab — 350 entries on the reported machine — leaving the tab blank and the app
  unresponsive. Settings lists the entries that are skipped, so it is clear why they are missing.
- MCP servers configured in Cursor now appear in the list. `~/.cursor/mcp.json` accepts `//`
  comments and ManageArms did not, so one commented-out entry hid every server in the file. Files
  containing comments are never rewritten, so anything you commented out stays where you put it.
- Configuration files that cannot be parsed now name the file and what to do about it, instead of
  showing a raw `NSCocoaErrorDomain` dump.
- Error messages now appear in English in the English interface. Messages raised while
  scanning, installing, updating, pinning and editing permissions were left untranslated, as
  were list details such as the "disabled (parked)" label and broken-link notes.
- Disabling a skill or subagent no longer leaves it half-disabled when the operation cannot
  finish. Previously the Claude symlink was removed first, so a later failure hid the skill
  from Claude while the list still showed it as enabled.
- Removing several project items at once now runs the command shown in the sheet. On the Codex
  screen it displayed `codex plugin remove` but ran the Claude equivalent, which then failed
  with an unrelated message.
- Applying an update no longer keeps reporting that an update is available afterwards.
- Refreshing after an action no longer gets dropped when a scan is already running, which
  could leave the list showing stale contents.
- A skill description ending near the 4 KB front-matter limit no longer shows a replacement
  character in place of its last character.

### Changed

- Returning to ManageArms is faster: the command-line tools for each agent are queried at most
  every few minutes instead of on every activation. Explicit refreshes, agent settings changes
  and removals still query immediately.
- Toggling, removing, updating and editing permissions no longer block the interface while
  files are moved or copied.
- Permission backups are capped at five generations per settings file, and recorded last-used
  dates are capped, so neither grows without bound.

## [0.1.0] — 2026-09-06

### Fixed

- Skill last-used dates now include Claude Code, Codex and Cursor session logs. Existing
  registries backfill newly supported sources on the next usage analysis.

## [0.0.1] — 2026-09-06

### Changed

- Downloads have moved to a dedicated public repository,
  [den0206/manage-arms-releases](https://github.com/den0206/manage-arms-releases). Get the DMG
  from its Releases page — it also carries the user-facing README in English and Japanese.
- Settings now has an Appearance option: follow the system, or force light or dark. It applies
  to the whole app, including the menu bar menu and sheets, and is remembered across launches.
- Refreshed the app icon: a calmer indigo backdrop with a colour-coded node for each agent, so
  it stays readable at Dock and menu-bar sizes.

### Added

- ManageArms now stays in the menu bar, so browser detection keeps working after you close the
  window. Its icon turns green when something has been found; open the menu to add it or
  dismiss it, or just navigate away — the icon goes back to normal when you leave the page.
  Closing the window drops the scanned list from memory, and nothing is scanned
  again until you open it. Turn residency off in Settings to go back to quitting on close.
- A Settings screen in the sidebar (⌘, or the menu bar item) holding the menu bar and browser
  detection switches.
- Browser detection: opening a skill, plugin or subagent page in Safari, Chrome, Edge, Brave or
  Arc while that browser is frontmost offers to add it, so no URL has to be copied. It is on by
  default, asks for permission to control the browser the first time a browser comes to the
  front, and turns itself off if permission is declined. No notification permission is
  requested. Pages are confirmed against `raw.githubusercontent.com` first, and URLs are never
  stored.

- Catalog URLs such as `skills.sh/<owner>/<repo>/<skill>` are accepted in the Add sheet and
  resolved to the GitHub repository they are published from. The skill name in the URL is a
  directory name rather than a path, so it pre-fills the candidate filter instead of being
  used as a subdirectory.
- A filter field over the candidate list when a fetched repository offers more than one item.
- Per-agent switches on Home: turn an agent off to drop it from the sidebar and stop scanning its
  MCP servers and plugins. Nothing on disk is touched — the switch only changes what manage-arms
  looks at.
- A manual CLI path for agents that cannot be found on your `PATH`, set from the agent list on Home
  and cleared from the same menu. A path that stops working falls back to `PATH` lookup instead of
  reporting the agent as detected.
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

- Reserved skills.sh pages such as `skills.sh/about` and `skills.sh/agent/claude-code` are no
  longer read as `<owner>/<repo>`, which sent the Add sheet off to fetch a repository that does
  not exist.

- Removing an MCP server or a plugin now confirms it is actually gone instead of trusting the
  CLI's exit code, and reports a failure when it is still there. Agent-default entries can report
  success without being removed, which previously left the row in place with no explanation.
  The confirmation only reports a failure when the entry can be read back and is still present,
  so an unreadable list is never mistaken for a failed removal, and removing a project-scoped
  server no longer reports failure when a server of the same name also exists at project scope.
- Codex plugins that ship installed by default (`installPolicy: INSTALLED_BY_DEFAULT`, the
  `openai-curated-remote` set) are now grouped under Bundled and shown as protected. They were
  listed user-wide with a Remove button, which buried the plugins you installed yourself and
  offered to delete something the agent reinstalls.
- Project skills in subdirectories are now listed. Claude Code loads `.claude/skills` from
  nested directories as well as the project root, so a monorepo package carrying its own skills
  was invisible in manage-arms. The walk stops three levels below the project root and skips
  hidden and dependency directories. A nested skill is shown under its qualified name
  (`apps/web:deploy`) only when the name collides, matching how Claude Code names it, and its
  removal command points at the subdirectory it actually lives in.
- Pasting a repository root now lists the skills nested under it. Skills laid out as
  `skills/<category>/<name>` were invisible because only one directory level was searched, and a
  repository carrying `.claude-plugin/plugin.json` stopped the search entirely — its skills are
  now listed alongside the plugin. Subagent detection still looks only at the directory you
  pointed at.
- The Add sheet now explains why a pasted URL was rejected instead of leaving the button disabled
  with no reason.
- Keep same-named resources separate by kind and MCP/plugin registrations separate by agent;
  pin MCP versions only for the selected agent and preserve unrelated Cursor settings.
- Refuse malformed configuration overwrites and protect bundled paths and links from deletion.
- Correct Claude MCP environment/header argument placement and Codex plugin command syntax.
- Correct the same argument placement for Gemini CLI, where the server name could be
  consumed as the value of a preceding `-e` flag.
- Messages for failed scans, additions and removals are now translated instead of always
  appearing in English.

[Unreleased]: https://github.com/den0206/manage-arms/compare/Ver_0.1.0...HEAD
[0.1.0]: https://github.com/den0206/manage-arms/compare/Ver_0.0.1...Ver_0.1.0
[0.0.1]: https://github.com/den0206/manage-arms/releases/tag/Ver_0.0.1
