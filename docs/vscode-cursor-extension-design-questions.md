# Agent Tool — 設計決定記録

## D-1. 対応環境

macOS、Linux、Windows のすべてで機能を提供する。OS 固有のパスは VS Code と
Node.js 標準ライブラリで解決し、リンクは macOS/Linux で symlink、Windows で
junction または hardlink を使う。

## D-2. 実装

すべての管理ロジックは拡張内の TypeScript モジュールで実行する。配布物に
プラットフォーム固有の実行ファイルは含めない。

## D-3. 保存先

可変メタデータは `context.globalStorageUri` の `registry.json` だけに保存する。
Skill と Subagent の実体はエージェントが読む既知の管理ルートに置く。

## D-4. 安全な書き込み

`writeGuard.ts`、`registry.ts`、`mcpScanner.ts` だけが書き込みを行う。
名前、親ディレクトリ、symlink/junction、管理ルートを検証してから操作する。

## D-5. 削除

削除は確認後に実行する。Undo と恒久バックアップは持たない。

## D-6. UI

Dashboard は表示中だけ一覧の再取得と MCP ポーリングを行う。View を閉じるか
非表示にした時点でタイマー、キャッシュ、スナップショットを破棄する。

## D-7. 信頼境界

未信頼ワークスペースと Remote 環境では書き込み操作を拒否する。走査対象は
`source.ts` のホワイトリストに限定する。

## D-8. プロセス状態

MCP サーバーの状態は登録済み定義とプロセス親子関係を照合して判断する。
ホームやワークスペースを再帰走査しない。

## D-9. 配布と検証

Node.js の型検査・テスト・不変条件検査を 3 OS で実行する。Cursor の E2E は
固定した Cursor Stable を macOS で実行する。第三者 GitHub Action は完全 SHA を使う。
