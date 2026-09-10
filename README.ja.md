# Agent Tool

Agent Toolは、AIコーディングエージェントのSkill、Subagent、MCPサーバー、Pluginを横断管理するCursor拡張です。

ManageArms（macOSアプリ）で検証済みの管理Coreを、ローカルで動作するエディタ拡張へ移行しています。macOS / Linux / Windowsで動作します。

## 状態

管理CoreはTypeScriptに統一済みです。Swift Coreと同梱CLIを撤去し、すべての操作を拡張内で実行します。進捗は[リリース計画](docs/agent-tool-release-plan.md)を参照してください。

## 開発

Node.js 20が必要です。

```bash
npm ci
npm run check      # 型検査・テスト・不変条件検査
npm run package
```

拡張のキャッシュはメモリだけに保持します。可変メタデータはCursorの`globalStorageUri`に置く`registry.json`だけとし、一時ダウンロード・展開物は成功・失敗を問わず削除します。

## ドキュメント

- [プロダクト要件](docs/product-requirements.md)
- [設計決定](docs/vscode-cursor-extension-design-questions.md)
- [モジュールAPI](docs/agent-tool-cli-api.md)
- [ストレージと移行](docs/agent-tool-data-spec.md)
- [セキュリティ](docs/agent-tool-security.md)
- [テスト計画](docs/agent-tool-test-plan.md)
- [リリース計画と進捗](docs/agent-tool-release-plan.md)

## ライセンス

[MIT](LICENSE)

[English](README.md)
