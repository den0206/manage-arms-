# Agent Tool

Agent Toolは、AIコーディングエージェントのSkill、Subagent、MCPサーバー、Pluginを横断管理するCursor拡張です。

ManageArmsで検証済みのSwift管理Coreを、ローカルで動作するCursor拡張へ移行しています。初版はmacOS版Cursorを対象にします。

## 状態

Phase 0を進行中です。リポジトリとSwift Coreの改名、旧Mac Appの撤去、拡張開発環境の整備を行っています。進捗は[リリース計画](docs/agent-tool-release-plan.md)を参照してください。

## 開発

macOS 26、Swift 6.2、Node.js 20が必要です。

```bash
swift build
swift test
./scripts/check-invariants.sh

npm ci
npm run typecheck
npm test
npm run package
```

拡張のキャッシュはメモリだけに保持します。可変メタデータはCursorの`globalStorageUri`に置く`registry.json`だけとし、一時ダウンロード・展開物は成功・失敗を問わず削除します。

## ドキュメント

- [プロダクト要件](docs/product-requirements.md)
- [設計決定](docs/vscode-cursor-extension-design-questions.md)
- [CLI API](docs/agent-tool-cli-api.md)
- [ストレージと移行](docs/agent-tool-data-spec.md)
- [セキュリティ](docs/agent-tool-security.md)
- [テスト計画](docs/agent-tool-test-plan.md)
- [リリース計画と進捗](docs/agent-tool-release-plan.md)

## ライセンス

[MIT](LICENSE)

[English](README.md)
