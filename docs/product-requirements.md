# Agent Tool — プロダクト要件書

> 設計決定の根拠は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。

## 概要

AI コーディングエージェントの周辺リソース（MCP サーバー・Skill・Subagent・Plugin）を横断管理する Cursor 拡張。
現行の ManageArms macOS アプリを置き換える。

| 項目 | 値 |
|---|---|
| 拡張 ID | `agent-tool` |
| 対象エディタ | Cursor（VS Code は後続フェーズ） |
| 対象 OS | macOS（AgentToolCore CLI）、Cursor が動く OS（拡張 UI） |
| ライセンス | MIT |
| ソースコード | 全公開 |

---

## 対象機能（初版スコープ）

### 1. Tool 一覧表示

- Activity Bar に **Agent Tool** パネルを追加する
- Tree View を 2 セクションに分割して常時表示する
  - **Current Project**（`.claude/` 配下）: Skills / Subagents / MCP Servers
  - **User Global**（`~/.claude/` 配下）: Skills / Subagents / MCP Servers
- どのワークスペースを開いていても両セクションを参照できる
- MCP サーバーの起動状態を View 表示中のみ 3 秒ポーリングで取得する

### 2. PATH 検知と AI エージェント CLI 表示

- 拡張起動時にログインシェル（`$SHELL -l -c 'echo $PATH'`）で PATH を解決する
- 以下の CLI の有無とバージョンを Tree View または Status Bar に表示する
  - `claude` / `cursor` / `codex` / `gemini`
- CLI が見つからない場合は未インストールとして表示し、インストール導線を示す
- Remote SSH / Dev Container / Codespaces 上では「ローカル環境のみ対応」と表示してこの機能を無効化する

### 3. Tool の追加

- URL 貼り付けコマンドでリポジトリを指定して追加する
- クリップボードに GitHub URL があれば Quick Pick で候補として提示する
- 公開リポジトリのみ対応（未認証）

### 4. Tool の削除・有効化・無効化

- Tree View のコンテキストメニューまたはインラインボタンから操作する
- 削除・上書き・CLI による設定変更の前に確認ダイアログを表示する（実行ファイル・引数・対象を明示）
- 削除は OS のゴミ箱へ移動し、操作単位のロールバックも提供する

### 5. 更新

- 更新可否を Tree View のバッジまたはインジケータで示す
- 差分は VS Code 標準 Diff Editor で表示する
- 更新の適用前に確認ダイアログを表示する

### 6. 設定移行（初回のみ）

- 起動時に `~/Library/Application Support/ManageArms/registry.json` を検知したら確認画面を表示し、`globalStorageUri` へ移行する

---

## 対象外機能（初版スコープ外）

| 機能 | 理由 |
|---|---|
| macOS メニューバー常駐 | Cursor 拡張では実現不可 |
| ブラウザ検知・自動 Tool 発見 | 廃止 |
| Remote SSH / Dev Container / Codespaces 対応 | ローカル限定設計。非対応を明示して表示 |
| Windows / Linux での AgentToolCore CLI | macOS 先行。後続フェーズで判断 |
| VS Code 対応 | 後続フェーズ |
| 非公開リポジトリからの取得 | 初版は公開リポジトリのみ |
| テレメトリ | 導入しない |
| Settings Sync 経由のマルチマシン同期 | 後続フェーズ |

---

## 機能要件

### 安全性

- **WriteGuard**: AgentToolCore CLI 内に維持する。書き込み許可ルート・symlink 検証・設定ファイル保護・SQLite 拒否を現行と同等に維持する
- **排他ロック**: 複数 Cursor ウィンドウ同時起動時は操作ごとのロックファイルで書き込みを制御する
- **未信頼ワークスペース**: 一覧表示のみ許可。CLI 実行・書き込みは禁止する

### データ

- **永続ストレージ**: VS Code `globalStorageUri`（`registry.json` 1 ファイルのみ）
- **書き込み**: アトミック書き込み（クラッシュ耐性）
- **キャッシュ**: CLI 取得結果を約 180 秒保持。明示的な更新・操作直後は無効化する
- **再走査**: View を開いた時と手動更新時。`~/.claude/`・`.claude/` 配下の設定ファイルのみファイル監視

### 通信

- **Extension Host**: `extensionKind: ["ui"]`（ローカル限定）
- **TS 拡張 ↔ CLI**: 1コマンド 1 JSON 入出力。起動時に `protocolVersion` を確認する
- **CLI 配布**: Universal Binary を VSIX に同梱する

### ログ・診断

- CLI の stdout / stderr はメモリ上で直近のみ保持し、終了時に破棄する
- シークレット（`--token`・`Bearer …` など）はログ出力前にマスクする

---

## 非機能要件

| 指標 | 目標値 |
|---|---|
| 起動〜一覧表示 | < 300 ms（キャッシュヒット時） |
| 拡張自体のメモリ使用 | 常駐時 < 65 MB |
| VSIX サイズ | < 20 MB（Universal Binary 同梱含む） |
| CLI タイムアウト | 180 秒（SIGTERM → SIGKILL） |
| CLI 出力上限 | 2 MB |

---

## リリース条件

### プロトタイプ（社内確認用）

- [ ] Tool 一覧の表示（Current Project + User Global）
- [ ] PATH 検知による AI エージェント CLI 表示
- [ ] 追加・削除の基本フロー（確認ダイアログあり）
- [ ] AgentToolCore CLI のコマンド 3 件以上が動作する

### β版（GitHub Releases VSIX）

- [ ] 全対象機能（1〜6）が動作する
- [ ] WriteGuard が現行と同等に機能する
- [ ] 未信頼ワークスペースで書き込みが禁止される
- [ ] Remote 環境で非対応メッセージが表示される
- [ ] 既存 375 テストがすべてパスする
- [ ] Cursor Stable での E2E テストがパスする

### 正式リリース（Cursor Marketplace）

- [ ] β版を 1 か月以上安定稼働
- [ ] Mac App の全管理機能と同等
- [ ] 初回移行フロー（ManageArms registry.json の自動検知と移行）が動作する

### Mac App 削除条件

- [ ] 正式リリース条件をすべて満たしている
- [ ] Agent Tool リポジトリのリネーム（`manage-arms` → `agent-tool`）完了
- [ ] ManageArms 関連の名称がコード・ドキュメントから除去されている

---

## 関連ドキュメント

- [設計決定記録](vscode-cursor-extension-design-questions.md)
- [AgentToolCore CLI API 仕様](agent-tool-cli-api.md)（次フェーズで作成）
- [データ・ロック・移行仕様](agent-tool-data-spec.md)（次フェーズで作成）
