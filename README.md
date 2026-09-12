<p align="center">
  <img src="media/icon.png" width="160" alt="Agent Tool icon">
</p>

**Find Skills, Install Easily!**

# Agent Tool

[![CI](https://github.com/den0206/agent-tool/actions/workflows/ci.yml/badge.svg)](https://github.com/den0206/agent-tool/actions/workflows/ci.yml)
[![GitHub Release](https://img.shields.io/github/v/release/den0206/agent-tool?include_prereleases&sort=semver)](https://github.com/den0206/agent-tool/releases)
[![Open VSX](https://img.shields.io/open-vsx/v/yuuki-sakai/agent-tool)](https://open-vsx.org/extension/yuuki-sakai/agent-tool)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Agent Tool is a Cursor extension for managing Skills, Subagents, MCP servers, and Plugins across AI coding agents.

<p align="center">
  <img src="media/demo.gif" width="1200" alt="Pluginを導入する動作">
</p>

## Overview

Agent Tool keeps the resources used by your coding agents discoverable from one editor view. It scans the agents' supported locations and delegates agent-owned operations to their official CLI.

## Features

- See Skills, Subagents, MCP servers, and Plugins in one dashboard.
- Install Skills and Subagents from GitHub and supported catalogs.
- Install Claude Code and Codex Plugins, including Plugins in GitHub subdirectories.
- Preview descriptions, locations, scopes, enabled state, and available updates.
- Work across user and project resources without copying managed files.
- Install Skills and Subagents straight from the browser with the companion Chrome/Edge extension.
- Run on macOS, Linux, and Windows.

## Requirements

- Cursor with extension support for Node.js 20 or later.
- The agent CLI you want to inspect or manage, such as Claude Code or Codex.
- Internet access when fetching a remote source or registering a Plugin Marketplace.

## Installation

Download the `.vsix` file from the [GitHub Releases](https://github.com/den0206/agent-tool/releases) page, then install it with:

```bash
code --install-extension agent-tool-X.Y.Z.vsix
# or use: cursor --install-extension agent-tool-X.Y.Z.vsix
```

You can also use **Install from VSIX…** in the Extensions view. Stable releases are published to [Open VSX](https://open-vsx.org/extension/yuuki-sakai/agent-tool) as well.

## Supported sources

Paste a URL from any of these into the extension's URL field.

| Site                                             | Example URL                                           | How the source is resolved                                                                      |
| ------------------------------------------------ | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| [GitHub](https://github.com/)                    | `https://github.com/owner/repo/tree/main/skills/pdf`  | From the URL.                                                                                   |
| [skills.sh](https://skills.sh/)                  | `https://skills.sh/anthropics/skills/frontend-design` | From the URL — `owner/repo` is part of the path.                                                |
| [Agents Directory](https://agentsdirectory.dev/) | `https://agentsdirectory.dev/skills/frontend-design/` | The page is read once, and only its schema.org JSON-LD metadata is used to find the repository. |

Sites are declared in `CATALOG_SITES` in `core/github.ts`, which both extensions read, so a new site reaches both at once. The browser extension also needs the host in its manifest. The page HTML is never scraped — a site whose URL does not carry `owner/repo` must publish a JSON-LD `codeRepository` or `url`.

## Browser extension

A companion extension for Chrome and Edge spots Skills and Subagents while you browse the supported sources above and installs them without leaving the page. It works on its own — the Cursor extension is not required.

- It writes only into folders you pick yourself, through the File System Access API. Pick an agent's config directory (`~/.claude`, `~/.cursor`, `~/.codex`, or the shared `~/.agents`) once, and Skills and Subagents are placed under it.
- Pages you visit are never stored. Only the directory handles, the list of what it installed, and the auto-open setting are kept.
- It records where each tool came from next to the files it wrote. If you also use the Cursor extension, it picks those up on its next scan, so the tool can be removed, disabled, and updated from the dashboard like anything else.

Build it with `npm run package:browser`. That produces `vsix/agent-tool-browser.zip` for the stores, and `vsix/browser/` which you can load through **Load unpacked** on `chrome://extensions`.

## Usage

1. Open Cursor and activate Agent Tool from the Activity Bar.
2. Review the User Global and project sections in the dashboard.
3. Use the add action to paste a supported GitHub or catalog URL.
4. Select a detected Skill, Subagent, MCP server, or Plugin and confirm the operation.
5. Use the refresh and update actions when you want to rescan sources or check remote revisions.

Plugin installation is delegated to Claude Code or Codex. For Claude Code, a Marketplace is registered before the Plugin is installed.

## Development

Requirements: Node.js 20.

```bash
npm ci
npm run check      # typecheck + tests + invariant checks
npm run package
```

The extension uses only in-memory caches. Its only mutable metadata file is `registry.json` under Cursor's `globalStorageUri`; temporary downloads and extraction directories are removed on every exit path.

Press F5 in Cursor or VS Code to launch an Extension Development Host.

## Release

Create and push a branch named `release/Ver_X.Y.Z`. GitHub Actions runs the checks, creates one VSIX, records its SHA-256 checksum, and attaches it to the GitHub Release. Stable releases are also published to Open VSX when the `OVSX_PAT` secret is configured.

## Documentation

- [Product requirements](docs/product-requirements.md)
- [Design decisions](docs/vscode-cursor-extension-design-questions.md)
- [Module API](docs/agent-tool-cli-api.md)
- [Storage and locking](docs/agent-tool-data-spec.md)
- [Security](docs/agent-tool-security.md)
- [Test plan](docs/agent-tool-test-plan.md)
- [Release plan and progress](docs/agent-tool-release-plan.md)

## License

[MIT](LICENSE)

[日本語](README.ja.md)
