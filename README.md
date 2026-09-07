# ManageArms

*English · [日本語](README.ja.md)*

A macOS app that manages the resources around AI coding agents — **MCP servers, Skills,
Subagents and Plugins** — for Claude Code, Cursor, Codex and Gemini CLI in one window.

It exists to stop you from registering the same resource again and again, once per agent,
in a different place and a different format each time.
The design document is [DESIGN.md](DESIGN.md) (Japanese).

## What it does

| | |
|---|---|
| **One screen per agent** | Pick an agent in the sidebar and you see only what that agent carries. **What you installed yourself comes first — plugins and MCP servers included, with a note on where they are managed — and whatever ships with the agent is folded away** |
| **Add** | Review skills from GitHub; add MCP using JSON, an endpoint URL, or a command; add plugins by name and marketplace. Choose the destination agent |
| **Enable / disable / delete** | Toggle app-managed shared skills. Remove existing user tools by location or agent: files go to Trash; MCP and plugins are unregistered through their manager |
| **Bundled protection** | Known bundled skill paths, tools with protection metadata, and links into plugin storage are protected |
| **Update** | Review the `SKILL.md` diff before applying. Pin a resource to stop updates when upstream changes direction |
| **Scope** | A tab for "all projects", one per project, and one for what ships with the agent — with a warning when the same thing is installed both ways, and bulk removal of the project copies |
| **Usage** | Last-used dates from Claude Code, Codex and Cursor session logs. MCP processes checked every 3 seconds while a window is visible; this does not indicate an active tool call |
| **Browser detection** | On by default. Opening a skill, plugin or subagent page while a browser is frontmost turns the menu bar icon green and offers to add it; leaving the page turns it back — no URL to copy, and no system notifications. The page is confirmed against `raw.githubusercontent.com` first, and the URL is never stored |
| **Permission cleanup** | Remove machine-specific and cross-project duplicate entries from `permissions.allow` |
| **Appearance** | Switch between light, dark and following the system in Settings (system by default) |

## Requirements

- macOS 26 or later
- Xcode 26 / Swift 6.2 or later to build

## Install

Download the DMG from [Releases](https://github.com/den0206/manage-arms-releases/releases/latest) and drag
`ManageArms.app` into your Applications folder.

If you launch it straight from the mounted disk image, the app offers to move itself into
the Applications folder on startup.

## Build and run

The project is a Swift Package — there is no `.xcodeproj` (open `Package.swift` in Xcode
directly).

```bash
swift test                  # unit tests (381 @Test declarations)
swift build                 # compile check

# The distributable form is a hand-assembled .app bundle.
# build-app.sh assembles and signs it.
CONFIG=debug UNIVERSAL=0 ./Scripts/build-app.sh   # development build (native arch, fast)
open ".build/debug/ManageArms Debug.app"
```

`swift run ManageArms` launches, but `Bundle.main` cannot resolve `Info.plist`, the icon or
the localizations. **Build the `.app` and run that.** A GUI process launched from Finder has
`PATH` set to only `/usr/bin:/bin:/usr/sbin:/sbin`, where none of `claude`, `codex` or
`gemini` can be found — `ShellPath` recovers the real one from the login shell. That
behaviour only reproduces once you run the `.app`.

### F5 in VS Code / Cursor

`.vscode/{launch,tasks}.json` are included. **F5** assembles the debug `.app` and launches it
(requires the CodeLLDB extension). Without a debugger extension, **Cmd+Shift+B** builds and
runs. Pick "Run ManageArms Debug.app (English)" to launch with the English UI.

**Debug builds are assembled as a separate app** (`com.yuukisakai.manage-arms.debug` /
`ManageArms Debug.app`). Its storage is `~/Library/Application Support/ManageArms Debug`, so
rebuilding during development never damages the `registry.json` of an installed release.

> Only the Application Support directory is separated. `~/.agents/skills` and
> `~/.claude/skills` are shared roots keyed on your home directory, so **enabling and
> disabling skills from a debug build still affects your real environment.**

## Layout

```
Sources/
├── ManageArmsCore/     scanning, install, update, usage, permissions — the tested layer.
│                       External dependencies are injected through Environment
│                       (a struct of closures, not a protocol)
└── ManageArms/         SwiftUI shell (Home / one screen per agent / Permissions)
Localization/           ja / en. Keys are the Japanese strings themselves
Resources/              Info.plist / entitlements / app icon
Scripts/                .app assembly, DMG, CHANGELOG cutting, invariant checks
docs/signing.md         Developer ID signing and notarization setup (Japanese)
```

## Security

- **No App Sandbox.** The app reads and writes other agents' configuration and launches
  their CLIs, which sandboxing forbids → the Mac App Store is not an option, so it is
  distributed directly with a Developer ID signature, notarization and Hardened Runtime
- **Scanning is whitelist-based.** A path not in the enumeration is never read, even if it
  exists (this is what keeps the 129 MB of `~/.claude/projects` and the `logs_*.sqlite`
  files out of a scan)
- **What may be deleted or moved is limited**, not what may not be. Any path that bypasses
  `WriteGuard` fails CI
- Configuration is written back in only three places. Adding and removing MCP servers and
  plugins is delegated to each agent's own CLI — `~/.claude.json` is 98 KB of interleaved
  state, and writing it back would race a running Claude and destroy all of it
- Permission removal rewrites only the `permissions` key and backs up the previous contents
- **No storage of its own beyond one file.** No cache directory; `URLSession` runs
  `.ephemeral`; temporary work happens in the system temporary directory
- **Browser detection is narrow, and you can turn it off.** It asks for permission to
  control the browser the first time a browser comes to the front, and stops itself if you
  decline. It runs only while a browser is frontmost, and asks for no notification
  permission — findings show up as a green menu bar icon. URLs are examined for
  `github.com` and `skills.sh` and then discarded — never written to disk or logged
- **Staying in the menu bar costs nothing while idle.** Closing the window drops the
  scanned list from memory; nothing is scanned again until you open it
- Zero third-party dependencies

## Releases

Push a `release/Ver_X.Y.Z` branch off `main` and CI runs tests → signed build →
notarization → DMG → GitHub Release. Setup and procedure are in
[docs/signing.md](docs/signing.md) (Japanese).

**Releases are published to a separate public repository**,
[den0206/manage-arms-releases](https://github.com/den0206/manage-arms-releases) — the source
stays private while the downloads stay public. That repository also holds the user-facing
README (English and Japanese), the changelog and the issue templates, and updates its own
"latest release" markers whenever a release is published.

**Signing and notarization are mandatory.** If any secret is missing the workflow stops
immediately; an unsigned DMG is never produced. A tag that already exists is never
overwritten — the build is published as `Ver_X.Y.Z+N` instead.

## Compatibility checks and limitations

`Scripts/check-agent-compatibility.sh claude` (or `codex` / `gemini`) downloads the latest CLI
into a temporary prefix, then verifies MCP registration, reading, removal, argument/environment/header
preservation, and plugin CLI contracts in a disposable home without inherited credentials.
An optional second argument selects a version. CI runs the same script daily and on demand.
Normal `swift test` skips these live CLI checks.

New MCP/plugin installations use user scope. Cursor plugin management, active tool-call events,
and automatic classification of unknown bundled formats are not supported. A missing local process
does not mean an HTTP MCP endpoint is stopped. Explicit project folders are scanned for Claude settings.
Installing plugin payloads and interacting with the GUI still require separate checks.
See [DESIGN.md, section 15](DESIGN.md) for the implementation boundaries.
