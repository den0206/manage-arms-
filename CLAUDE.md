# CLAUDE.md — Agent Tool 作業ガイド

AI エージェントの周辺リソース（MCP / Skills / Subagents / Plugins）を管理する
Cursor 拡張 **Agent Tool** へ、ManageArms macOS アプリから段階的に移行する。
Swift 6 / TypeScript。Swift Core は外部依存ゼロを維持する。

## 設計の正本

| ファイル | 役割 |
|---|---|
| `docs/product-requirements.md` | 移行後の対象機能・完了条件 |
| `docs/vscode-cursor-extension-design-questions.md` | 設計決定と理由 |
| `docs/agent-tool-cli-api.md` | TypeScript 拡張と Swift CLI の境界 |
| `docs/agent-tool-data-spec.md` | ストレージ・ロック・移行 |
| `docs/agent-tool-ui-design.md` | Tree View と操作フロー |
| `docs/agent-tool-security.md` | WriteGuard・権限・信頼境界 |
| `docs/agent-tool-test-plan.md` | Swift / TypeScript / Cursor の検証 |
| `docs/agent-tool-release-plan.md` | Phase 0 の改名・撤去と開発・配布順序 |
| `DESIGN.md` | Phase 0 で削除する現行 Mac App の実装確認用 |

Agent Tool の判断では `docs/agent-tool-*.md` を優先する。仕様を複製せず、該当する正本を更新する。

## 移行中の境界

- 製品・拡張名は **Agent Tool**、拡張 ID は `agent-tool`。
- Phase 0 で既存リポジトリとローカルディレクトリを `agent-tool`、Coreを `AgentToolCore` へ変更する。
- Mac App、旧CHANGELOG、配布・署名・公証資産はmainから削除する。旧データの移行元パスだけ残す。
- TypeScript はルートの `src/` と `test/` に置き、`Scripts/` は `scripts/` へ変更する。
- Swift CLI は1コマンド1プロセス。プロセスをまたぐ状態を CLI メモリに置かない。
- TypeScript は Cursor API と表示、Swift CLI は走査・判定・書き込み・WriteGuard を担当する。
- TypeScript から Agent 設定や管理リソースを直接書かない。
- ManageArms が実行中なら破壊的CLI操作を拒否する。

## 完了の定義

Phase 0 完了まではSwift変更時に:

```bash
swift build && swift test
./Scripts/check-invariants.sh
./Scripts/release-changelog.sh --check && ./Scripts/test-release-changelog.sh
```

Phase 0 後は `scripts/` の同等コマンドを使う。`package.json` 追加後はNode 20で
テスト・型検査・VSIX組み立て・固定Cursor StableのE2Eも通す。
CI はローカルと同じスクリプトを呼び、別ロジックを持たせない。

## 絶対に守る不変条件

1. Agent 設定の書き込みは Swift Core の専用経路だけに置く。
   `registry.json` は `Registry`、Cursor の `mcp.json` は `MCPScanner` が扱う。
2. 削除・移動・symlink 作成は `WriteGuard` を通す。作成前に `assertValidName`、
   親 symlink は `assertSafeCreation` で検証する。
3. 走査対象は `Source` のホワイトリストだけにする。ホームやワークスペース全体を再帰走査しない。
4. 壊れた registry の上で書き込みを始めない。read-modify-write はプロセス間ロック内で行い、
   registry はアトミックに保存する。
5. 未信頼ワークスペースでは一覧だけを許可し、Remote 環境では CLI を起動しない。
6. UI 文言は `l10n/` の英語・日本語を同時に更新する。

不変条件スクリプトの許可リストを広げる場合は、ユーザーデータへ到達しない理由を
スクリプト内に記す。

## ストレージ・メモリ管理

リソース管理ツール自身がディスクとメモリを増やさないことを機能要件として扱う。

- 可変メタデータは `<globalStorageUri>/registry.json` だけ。`registry.lock` は内容を持たないロック inode。
- Skill / Subagent 実体は管理対象データであり、キャッシュではない。既存配置を再利用し、コピーを重複させない。
- ログ、診断履歴、Undo スナップショット、インベントリ、差分を永続化しない。
- CLI 由来の180秒キャッシュは拡張のメモリだけに置き、手動更新・書き込み直後・View 非表示で破棄する。
- MCP の3秒ポーリングとファイル監視は対象 View の表示中だけ動かし、再表示時に再走査する。
- CLI の stdout / stderr は各2 MBで打ち切り、マスク済みの直近分だけをメモリ保持する。
- HTTP は `URLSessionConfiguration.ephemeral` を使い、アーカイブをファイルへ流す。
- ダウンロード50 MB、展開後200 MB、単一ファイル20 MB、CLI出力2 MBの上限を維持する。
- 一時ダウンロード・展開・staging は OS の一時領域に置き、成功・失敗・キャンセルの全経路で削除する。
- 一覧では frontmatter の先頭4 KBだけを読む。本文は詳細表示中だけ保持し、閉じたら破棄する。
- Tree View は表示に必要な DTO だけを保持し、Swift の Inventory や本文を複製して常駐させない。
- 目標は一覧表示300 ms未満（メモリキャッシュ時）、常駐増分65 MB未満、VSIX 20 MB未満。

上限を緩めるのは、実測で不足が確認され、新しい上限と回収経路をテストできる場合だけにする。

## 実装パターン

- 外部依存は `Environment`（構造体 + クロージャ）で注入する。実装が1つの protocol を作らない。
- Agent は `enum Agent` と `switch` を使う。
- OS 操作は端へ寄せ、判定を純粋関数にして Swift Testing で検証する。
- CLI 入力は JSON の構造化フィールドで受け、区切り文字列から復元しない。
- CLI の失敗は安定したエラーコードとマスク済みメッセージで返す。
- Swift / Node.js / VS Code API の標準機能を優先し、必要になるまで依存を増やさない。

## テスト

- Swift は `Environment.test(home:)` を使い、実ユーザーのホームへ到達させない。
- 走査ホワイトリスト、WriteGuard、ロック、移行衝突、出力上限を優先する。
- TypeScript は CLI 境界、View のライフサイクル、Remote / Workspace Trust を検証する。
- Cursor E2E は固定URLとSHA-256のCursor Stable実行ファイルを明示して、全PRで起動する。
- UI スナップショットやモック自体を検証するテストは書かない。
- テスト件数を仕様に固定しない。完了条件は全テスト成功とする。

## ローカライズ・コミット

- 拡張の英語・日本語文言は `l10n/` で管理する。パス・コマンド・差分は verbatim で表示する。
- 日本語の Conventional Commits を使う。コミットと push はユーザーが求めた場合だけ行う。
- 利用者に見える変更は `CHANGELOG.md` の `[Unreleased]` に英語で追加する。
- README を変える場合は英語版と日本語版を同時に更新する。
- 役割が重なる文書・スクリプト・設定を増やさない。
- 実装後は `/ponytail:ponytail-review` で過剰実装を確認する。

## 配布・依存管理

- Secondary Simulator と同じくNode 20、npm、`package-lock.json`、Node標準 `node:test`を使う。
- 依存は必要最小限の正確な版に固定し、`ignore-scripts=true`、第三者Actionのcommit SHA固定を守る。
- Publisherは`yuuki-sakai`。alpha / betaはGitHub Releases、安定版は同じVSIXをOpen VSXからGitHubの順に公開する。
- Universal CLIは署名・公証しない。最初の公開前と配布経路変更時に、配布VSIXからの初回起動を実機確認する。
- 定期canaryは設けない。リリース前にRSSとAgent Tool自身の保存容量を計測する。
