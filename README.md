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
| **Add** | Paste a GitHub URL; the contents are fetched and shown. Nothing is installed until you confirm |
| **Enable / disable / delete** | Disabling parks the resource aside; deleting moves it to the Trash. Either way it can be brought back |
| **Adopt** | A skill you installed yourself can be brought under management without moving a single file |
| **Update** | Review the `SKILL.md` diff before applying. Pin a resource to stop updates when upstream changes direction |
| **Scope** | A tab for "all projects", one per project, and one for what ships with the agent — with a warning when the same thing is installed both ways, and bulk removal of the project copies |
| **Usage** | Last-used dates gathered from session logs. For MCP, which servers are running *right now* |
| **Permission cleanup** | Remove machine-specific and cross-project duplicate entries from `permissions.allow` |

## Requirements

- macOS 26 or later
- Xcode 26 / Swift 6.2 or later to build

## Install

Download the DMG from [Releases](https://github.com/den0206/manage-arms/releases) and drag
`ManageArms.app` into your Applications folder.

If you launch it straight from the mounted disk image, the app offers to move itself into
the Applications folder on startup.

## Build and run

The project is a Swift Package — there is no `.xcodeproj` (open `Package.swift` in Xcode
directly).

```bash
swift test                  # unit tests (271)
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
- Zero third-party dependencies

## Releases

Push a `release/Ver_X.Y.Z` branch off `main` and CI runs tests → signed build →
notarization → DMG → GitHub Release. Setup and procedure are in
[docs/signing.md](docs/signing.md) (Japanese).

**Signing and notarization are mandatory.** If any secret is missing the workflow stops
immediately; an unsigned DMG is never produced.
