# Agent Tool

Agent Tool is a Cursor extension for managing Skills, Subagents, MCP servers, and Plugins across AI coding agents.

The project is migrating the tested Swift management core from ManageArms into a local Cursor extension. The first release targets Cursor on macOS.

## Status

Phase 0 is in progress: the repository and Swift core are being renamed, the former Mac app is being removed, and the extension toolchain is being established. See [the release plan](docs/agent-tool-release-plan.md).

## Development

Requirements: macOS 26, Swift 6.2, and Node.js 20.

```bash
swift build
swift test
./scripts/check-invariants.sh

npm ci
npm run typecheck
npm test
npm run package
```

The extension uses only in-memory caches. Its only mutable metadata file is `registry.json` under Cursor's `globalStorageUri`; temporary downloads and extraction directories are removed on every exit path.

## Documentation

- [Product requirements](docs/product-requirements.md)
- [Design decisions](docs/vscode-cursor-extension-design-questions.md)
- [CLI API](docs/agent-tool-cli-api.md)
- [Storage and migration](docs/agent-tool-data-spec.md)
- [Security](docs/agent-tool-security.md)
- [Test plan](docs/agent-tool-test-plan.md)
- [Release plan and progress](docs/agent-tool-release-plan.md)

## License

[MIT](LICENSE)

[日本語](README.ja.md)
