# Agent Tool

Agent Tool is a Cursor extension for managing Skills, Subagents, MCP servers, and Plugins across AI coding agents.

The project is migrating the tested management core from the ManageArms macOS app into a local editor extension. It runs on macOS, Linux, and Windows.

## Status

The management core is now TypeScript only: the Swift core and its bundled CLI have been removed, and every operation runs inside the extension. See [the release plan](docs/agent-tool-release-plan.md).

## Development

Requirements: Node.js 20.

```bash
npm ci
npm run check      # typecheck + tests + invariant checks
npm run package
```

The extension uses only in-memory caches. Its only mutable metadata file is `registry.json` under Cursor's `globalStorageUri`; temporary downloads and extraction directories are removed on every exit path.

## Documentation

- [Product requirements](docs/product-requirements.md)
- [Design decisions](docs/vscode-cursor-extension-design-questions.md)
- [Module API](docs/agent-tool-cli-api.md)
- [Storage and migration](docs/agent-tool-data-spec.md)
- [Security](docs/agent-tool-security.md)
- [Test plan](docs/agent-tool-test-plan.md)
- [Release plan and progress](docs/agent-tool-release-plan.md)

## License

[MIT](LICENSE)

[日本語](README.ja.md)
