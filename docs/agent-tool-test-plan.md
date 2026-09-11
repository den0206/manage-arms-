# Agent Tool — テスト計画

## 自動テスト

Node.js `node:test` で TypeScript モジュールと VS Code API モックを検証する。
テストは偽ホームを使い、実ユーザーのエージェント設定を読み書きしない。

| 対象 | 確認内容 |
|---|---|
| WriteGuard / Registry | パス検証、原子的書き込み、ロック、設定・registry の読込上限 |
| 走査 | ホワイトリスト外を読まない |
| 追加・更新・削除 | 実体、リンク、設定の変更先 |
| Plugin | CLI コマンドと scope |
| Dashboard | 表示中のみポーリングし、非表示時に解放 |

## CI

Linux、macOS、Windows で `npm run typecheck` と `npm test` を実行する。
Linux で不変条件検査とリリース検査を実行する。`CURSOR_URL` と `CURSOR_SHA256` が
リポジトリ変数に設定されている場合は、macOS で固定 Cursor Stable の E2E と
VSIX サイズ検査も実行する。

## リリース前

配布した VSIX の初回起動、複数ウィンドウのロック、RSS、保存容量を実機で確認する。
