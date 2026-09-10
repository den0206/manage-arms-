# Agent Tool — プロダクト要件書

> 設計決定の根拠は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。

## 概要

AI コーディングエージェントの周辺リソース（MCP サーバー・Skill・Subagent・Plugin）を横断管理する Cursor 拡張。
現行の ManageArms macOS アプリを置き換える。

| 項目 | 値 |
|---|---|
| 拡張 ID | `agent-tool` |
| 対象エディタ | Cursor（VS Code は後続フェーズ） |
| 対象 OS | macOS / Linux / Windows。全 OS で全機能を提供（設計決定 D-1） |
| ライセンス | MIT |
| ソースコード | 最初の公開 VSIX より前に既存リポジトリを公開 |
| Publisher | `yuuki-sakai` |
| Node.js | 20 |

実装は TypeScript に統一し、リポジトリ直下の `src/`、`test/`、`media/`、`l10n/` に置く（設計決定 D-2）。
Swift Core と CLI は廃止する。

---

## 対象機能（初版スコープ）

### 1. Tool 一覧表示

- Activity Bar に **Agent Tool** パネルを追加する
- Tree View を **Scope → Agent → 種別 → Tool** の順に表示する
  - **Current Project**: Skills / Subagents / MCP Servers / Plugins
  - **User Global**: Skills / Subagents / MCP Servers / Plugins
- どのワークスペースを開いていても両セクションを参照できる
- MCP サーバーの起動状態を View 表示中のみ 3 秒ポーリングで取得する

### 2. PATH 検知と AI エージェント CLI 表示

- 拡張起動時にログインシェル（`$SHELL -l -c 'echo $PATH'`）で PATH を解決する。Windows は `powershell -Command $env:PATH` を使う
- 以下の CLI の有無とバージョンを Tree View または Status Bar に表示する
  - `claude` / `cursor` / `codex` / `gemini`
- CLI が見つからない場合は未インストールとして表示し、インストール導線を示す
- Remote SSH / Dev Container / Codespaces 上では「ローカル環境のみ対応」と表示してこの機能を無効化する

### 3. Skill / MCP の追加

- Skill は URL 貼り付けコマンドで公開リポジトリを指定して追加する
- クリップボードに GitHub URL があれば Quick Pick で候補として提示する
- MCP は構造化 JSON またはコマンドを確認画面で検証して追加する
- Subagent と Plugin の追加は各 Agent の標準導線へ委ねる

### 4. Tool の削除・有効化・無効化

- Tree View のコンテキストメニューまたはインラインボタンから操作する
- 削除・上書き・CLI による設定変更の前に確認ダイアログを表示する（実行ファイル・引数・対象を明示）
- 削除は確認ダイアログで承認を得てから実体とリンクを削除する。ゴミ箱移動と Undo は提供しない（設計決定 D-5）
- 更新は適用中の失敗時に元へ戻す。適用完了後の Undo は提供しない
- Plugin の削除は対象 Agent の CLI に委譲し、実行コマンドを確認画面に表示する

### 5. 更新

- 更新可否を Tree View のバッジまたはインジケータで示す
- 差分は VS Code 標準 Diff Editor で表示する
- 更新の適用前に確認ダイアログを表示する

### 6. 設定移行（初回のみ）

- macOS でのみ、起動時に `~/Library/Application Support/ManageArms/registry.json` を検知したら確認画面を表示し、`globalStorageUri` へ移行する（旧アプリは macOS 専用のため他 OS では検知しない）

---

## 対象外機能（初版スコープ外）

| 機能 | 理由 |
|---|---|
| macOS メニューバー常駐 | Cursor 拡張では実現不可 |
| ブラウザ検知・自動 Tool 発見 | 廃止 |
| Remote SSH / Dev Container / Codespaces 対応 | ローカル限定設計。非対応を明示して表示 |
| VS Code 対応 | 後続フェーズ |
| 非公開リポジトリからの取得 | 初版は公開リポジトリのみ |
| テレメトリ | 導入しない |
| Settings Sync 経由のマルチマシン同期 | 後続フェーズ |

---

## 機能要件

### 安全性

- **WriteGuard**: `src/writeGuard.ts` に維持する。書き込み許可ルート・リンク検証・設定ファイル保護・SQLite 拒否を現行と同等に維持する
- **排他ロック**: 複数 Cursor ウィンドウ同時起動時は操作ごとのロックファイルで書き込みを制御する
- **未信頼ワークスペース**: 一覧表示のみ許可。外部コマンド実行・書き込みは禁止する
- **旧Mac App**: macOS で ManageArms が実行中なら破壊的操作を拒否する

### データ

- **永続ストレージ**: VS Code `globalStorageUri`。可変メタデータは `registry.json` だけとし、管理対象の Skill / Subagent 実体以外を増やさない
- **書き込み**: アトミック書き込み（クラッシュ耐性）
- **キャッシュ**: 走査結果を拡張のメモリで約180秒保持。明示的な更新・操作直後・View 非表示で破棄する
- **再走査**: View を開いた時と手動更新時。`Source` ホワイトリスト内だけを View 表示中に監視する

### 実行構成

- **Extension Host**: `extensionKind: ["ui"]`（ローカル限定）
- **管理ロジック**: 拡張内の TypeScript モジュール呼び出し。サブプロセスの CLI は持たない
- **配布**: VSIX 単体。同梱バイナリと署名・公証は不要
- **外部コマンド**: プロセス一覧取得（`ps` / `Get-CimInstance`）と PATH 解決だけに限定する

### ログ・診断

- 外部コマンドの stdout / stderr は各2 MBで打ち切り、マスク済みの直近分だけをメモリ保持して終了時に破棄する
- シークレット（`--token`・`Bearer …` など）はログ出力前にマスクする

---

## 非機能要件

| 指標 | 目標値 |
|---|---|
| 起動〜一覧表示 | < 300 ms（キャッシュヒット時） |
| 拡張によるメモリ増分 | View 非表示時 < 65 MB |
| VSIX サイズ | < 20 MB |
| 外部コマンドのタイムアウト | 180 秒（SIGTERM → SIGKILL） |
| 外部コマンドの出力上限 | 2 MB |

---

## リリース条件

### プロトタイプ（社内確認用）

- [x] Tool 一覧の表示（Current Project + User Global）
- [ ] PATH 検知による AI エージェント CLI 表示
- [x] `inventory` / `scanPath` / `toggle` が 3 OS の偽ホームで動作する

### β版（GitHub Releases VSIX）

- [ ] 全対象機能（1〜6）が動作する
- [ ] WriteGuard が現行と同等に機能し、`scripts/check-invariants.sh` が通る
- [ ] 未信頼ワークスペースで書き込みが禁止される
- [ ] Remote 環境で非対応メッセージが表示される
- [ ] TypeScript の全テストが Linux / macOS / Windows でパスする
- [ ] Cursor Stable での E2E テストがパスする（macOS）
- [ ] ソースリポジトリが MIT で公開されている

### 正式リリース（Open VSX / Cursor）

- [ ] β版を 1 か月以上安定稼働
- [ ] Mac App の全管理機能と同等
- [ ] 初回移行フロー（ManageArms registry.json の自動検知と移行）が macOS で動作する
- [ ] Windows で junction / hardlink による追加・有効化・更新・削除が実機で動作する
- [ ] 同じ VSIX が Open VSX と GitHub Releases に公開されている

---

## 関連ドキュメント

- [設計決定記録](vscode-cursor-extension-design-questions.md)
- [TypeScript モジュール API 仕様](agent-tool-cli-api.md)
- [データ・ロック・移行仕様](agent-tool-data-spec.md)
- [UI設計](agent-tool-ui-design.md)
- [セキュリティ要件](agent-tool-security.md)
- [テスト計画](agent-tool-test-plan.md)
- [リリース計画](agent-tool-release-plan.md)
