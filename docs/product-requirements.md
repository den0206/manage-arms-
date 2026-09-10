# Agent Tool — プロダクト要件書

AI コーディングエージェントの Skill、Subagent、MCP サーバー、Plugin を管理する
Cursor 拡張。

| 項目 | 値 |
|---|---|
| 拡張 ID | `agent-tool` |
| 対象 OS | macOS / Linux / Windows |
| 実装 | TypeScript |
| 永続メタデータ | `globalStorageUri/registry.json` |

## 機能

- Dashboard でユーザー全体とワークスペースのツールを一覧表示する。
- 公開 GitHub URL から Skill、Subagent、Plugin を追加する。
- 構造化 JSON、HTTP URL、または安全なコマンドから MCP サーバーを追加する。
- 削除、有効化、無効化、更新プレビュー、更新適用を提供する。
- Plugin の設定変更は対象 CLI の実行コマンドを表示して確認を求める。

## 安全性

- 書き込みは `writeGuard.ts`、`registry.ts`、`mcpScanner.ts` に限定する。
- 未信頼ワークスペースと Remote 環境では書き込みを拒否する。
- 走査対象は `source.ts` のホワイトリストに限定する。
- 可変メタデータ以外のキャッシュ、ログ、Undo スナップショットを保存しない。

## リリース条件

- `npm run typecheck`、`npm test`、不変条件検査、リリース検査が通る。
- Linux、macOS、Windows で型検査とテストが通る。
- Cursor Stable の E2E と VSIX の 20 MB 上限を確認する。
