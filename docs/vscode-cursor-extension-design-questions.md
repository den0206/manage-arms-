# Agent Tool — Cursor 拡張版 設計決定記録

## 目的

ManageArms の機能を Cursor 拡張（Agent Tool）へ移行するにあたり、実装前に決めた事項の記録。
質問票形式から始まり、グリリングセッション（2026-09-10）で全項目を決定した。

## 追加要件（グリリングセッションで確定）

- **移行後の製品名を「Agent Tool」に統一**
  - Phase 0 で既存リポジトリとローカルディレクトリを `agent-tool` へ変更する。新規リポジトリは作らない
  - Mac App を main から削除し、`ManageArmsCore` を `AgentToolCore` へ変更する
- **拡張内の PATH を検知して使用中の Tool/Skill を前面表示**
  - ログインシェルの PATH から AI エージェント CLI（claude / cursor / codex / gemini）の有無とバージョンを表示
- **ユーザー全体（`~/.claude/`）と各 PJ（`.claude/`）の Tool を常に参照可能**
  - Tree View をセクション分割し、Current Project と User Global を常時表示
- **Mac App は退避済みブランチだけに残し、追加配布や移行告知は行わない**

## 現時点で分かっている制約

- MCP・Skill・Subagent・Plugin の管理機能は、Cursor 拡張へ概ね移行できる。
- macOS メニューバー常駐と IDE 終了後のブラウザ検知は廃止する。
- ローカルのホームディレクトリと CLI を扱うため、`extensionKind: ["ui"]` でローカル限定とする。
- Remote SSH・Dev Container・Codespaces では非対応として明示的にエラー表示する。
- 現行の Swift Core・WriteGuard・全テストは `AgentToolCore` へ改名して移行資産として維持する。

---

## A. プロトタイプ着手前に決める質問

### 1. 製品の位置づけ

#### Q1. 拡張版の最終目的は何か？

- A. Mac App を完全に置き換える
- B. Mac App と拡張版を恒久的に併用する
- C. 当初は併用し、十分な機能が揃った後に Mac App 廃止を判断する

**決定:** A — Phase 0 で Mac App を main から削除し、退避済みブランチだけに残す

#### Q2. 最初のリリースで対象にするエディタはどれか？

- A. VS Code のみ
- B. Cursor のみ
- C. VS Code と Cursor の両方

**決定:** B — Cursor のみ。VS Code 対応は後続フェーズ

#### Q3. 対応OSはどうするか？

- A. macOS のみ
- B. macOS を先行し、後から Windows/Linux を検討する
- C. 初版から macOS/Windows/Linux に対応する

**決定:** B — 初版は拡張 UI と AgentToolCore Swift CLI の両方を macOS のみ対象とする。
Windows / Linux では非対応メッセージだけを表示し、後続フェーズで対応を検討する

#### Q4. 初版で「移行完了」とみなす機能範囲はどこまでか？

- A. 一覧表示だけ
- B. 一覧＋追加・削除・有効化・更新
- C. Mac App の全機能

**決定:** B ＋ PATH 検知による使用中 Tool/Skill 表示。ブラウザ検知・常駐は廃止

#### Q5. ブラウザ検知とメニューバー機能をどう扱うか？

- A. 拡張版では廃止する
- B. Mac App 側の任意機能として残す
- C. 別のネイティブヘルパーとして残す
- D. ブラウザ拡張で代替する

**決定:** A — 廃止する

### 2. 中核アーキテクチャ

#### Q6. 管理ロジックをどの言語・構成で実装するか？

- A. 既存 Swift Core を CLI 化し、TypeScript 拡張から呼ぶ
- B. すべて TypeScript へ移植する
- C. Mac App をローカルサービス化し、拡張から接続する

**決定:** A — 既存 Core を Phase 0 で `AgentToolCore` へ改名し、`AgentToolCoreCLI` を TypeScript 拡張から呼ぶ。WriteGuard と全テストを維持する

#### Q7. Swift Core CLI を採用する場合、どう配布するか？

- A. Universal Binary を VSIX へ同梱する
- B. Homebrew で別途インストールしてもらう
- C. 初回起動時に署名済みバイナリをダウンロードする
- D. 既存 Mac App に同梱された CLI を利用する

**決定:** A — Universal Binary を VSIX に同梱する

#### Q8. 拡張と Core CLI の通信形式は何にするか？

- A. 1コマンド 1 JSON 入出力
- B. JSON Lines による継続プロセス
- C. Unix Domain Socket / JSON-RPC

**決定:** A — 1コマンド 1 JSON 入出力。必要になった時点で B へ移行を検討

#### Q9. Core CLI の API バージョン互換性をどう管理するか？

- A. 拡張と CLI を常に同一バージョンで配布する
- B. `protocolVersion` を持ち、前後 1 世代を互換にする
- C. 厳密な Semantic Versioning と複数世代互換を提供する

**決定:** A ＋ 起動時の `protocolVersion` 確認

#### Q10. 拡張はどこで実行させるか？

- A. 常にローカル UI Extension Host
- B. 常に Workspace Extension Host
- C. ローカル／リモートを設定で切り替える

**決定:** A — `extensionKind: ["ui"]` としてローカルの Agent 設定を管理する

#### Q11. Remote SSH、Dev Container、Codespaces では何を管理するか？

- A. ローカル Mac の Agent 設定のみ
- B. リモート環境の Agent 設定のみ
- C. ローカルとリモートを切り替え可能にする
- D. 初版では Remote 環境を非対応にする

**決定:** A — ローカル Mac の設定のみ管理。Remote 環境では非対応を明示してエラー表示

#### Q12. 複数ウィンドウ・Cursor 同時起動時の書き込みをどう制御するか？

- A. 操作ごとの排他ロックファイル
- B. 常駐 Core プロセスを 1 つだけ起動して書き込みを集中させる
- C. 同時起動は非対応として警告だけ出す

**決定:** A — 操作ごとの排他ロックファイル

### 3. データと移行

#### Q13. 永続データをどこに保存するか？

（元の選択肢は Mac App との共有を前提としていたが、Mac App 廃止により再設計）

- A. VS Code `globalStorageUri`（拡張が管理するディレクトリ）
- B. `~/.agent-tool/registry.json` など dotfile として独立配置
- C. 既存 `~/Library/Application Support/ManageArms/` をリネームして継続

**決定:** A — VS Code `globalStorageUri` へ移行する。`~/Library/Application Support/ManageArms/` からの初回移行処理を実装

#### Q14. Mac App と拡張版が同時にインストールされている期間を許可するか？

**決定:** Mac App の追加配布は行わない。既存インストールとの競合を避けるため、破壊的操作の直前に ManageArms の起動を検知したら操作を拒否する

#### Q15. 既存ユーザーの設定移行を自動化するか？

**決定:** 初回起動時に `~/Library/Application Support/ManageArms/registry.json` を検知して自動移行。確認画面を表示してから実行

### 4. UIの基本方針

#### Q16. メインUIは何を使うか？

- A. Activity Bar ＋ Tree View 中心
- B. Webview による現行画面の再現
- C. Tree View と Webview の併用

**決定:** A — Activity Bar ＋ Tree View 中心。追加などの複雑な操作のみ Quick Pick または Webview を使う

#### Q16b. Tree View の構造はどうするか？（追加決定）

**決定:** セクション分割（常に両方表示）

```
AGENT TOOL
▾ 📁 Current Project  (.claude/)
    ▾ Claude
        Skills
        Subagents
        MCP Servers
        Plugins
▾ 👤 User Global  (~/.claude/)
    ▾ Claude
        Skills
        Subagents
        MCP Servers
        Plugins
    ▾ Cursor
        Skills
        Subagents
        MCP Servers
        Plugins
    ▾ Codex
        Skills
        MCP Servers
    ▾ Gemini
        Skills
        MCP Servers
```

#### Q17. 更新差分をどのUIで表示するか？

- A. VS Code 標準 Diff Editor
- B. 専用 Webview
- C. Markdown プレビュー

**決定:** A — VS Code 標準 Diff Editor

#### Q18. エージェントごとの表示構造はどうするか？

- A. Agent → 種別 → Tool
- B. 種別 → Agent → Tool
- C. Tool 一覧に Agent バッジを付ける
- D. 3 方式を切り替え可能にする

**決定:** A を初期表示。横断検索結果では C を使う

#### Q19. 現行のホーム画面サマリーを残すか？

**決定:** Tree View のセクション構造（Q16b）で代替。専用サマリー画面は持たない

#### Q20. 「ブラウザで発見」の代わりとなる主要導線は何か？

**決定:** URL 貼り付けコマンド ＋ クリップボードから追加。URI Scheme は後続フェーズで検討

---

## B. β版までに決める質問

### 5. 安全性と権限

#### Q21. 未信頼ワークスペースではどこまで許可するか？

- A. 全機能を無効化する
- B. ユーザー全体の一覧だけ許可し、CLI 実行と書き込みを禁止する
- C. ユーザー全体の操作は許可し、プロジェクト操作だけ禁止する

**決定:** B

#### Q22. 破壊的操作の確認粒度をどうするか？

- A. 削除時だけ確認する
- B. 削除、上書き、CLI による設定変更で確認する
- C. 初回のみ包括同意を得る

**決定:** B — 削除・上書き・CLI による設定変更すべてで確認ダイアログを出す

#### Q23. CLI コマンドを UI 上に表示するか？

**決定:** B — 詳細を開いた場合だけ表示。実行ファイル・引数・対象 Agent を確認できるようにする

#### Q24. CLI の標準出力・標準エラーをどこまで保存するか？

**決定:** B — stdout / stderr は各2 MBを上限にプロセス終了までメモリ保持し、直後に破棄する。
UI にはマスク済みの要約だけを通知が閉じるまで保持する

#### Q25. GitHub 取得時の認証方法はどうするか？

**決定:** A — 公開リポジトリのみ・未認証。非公開リポジトリ対応時に VS Code GitHub Authentication API を追加

#### Q26. 現行の WriteGuard 不変条件をどこまで維持するか？

**決定:** A — 現行と同等を必須。書き込み許可ルート・symlink・設定ファイル・SQLite 拒否を維持。AgentToolCore Swift CLI 内に保持

#### Q27. 削除後の復旧方法をどうするか？

- A. OS のゴミ箱だけに任せる
- B. 操作単位のロールバック ＋ ゴミ箱
- C. 独自バックアップを持つ

**決定:** B — 削除は OS ゴミ箱へ移し、拡張が元パスとゴミ箱パスを30秒だけメモリ保持して復元できるようにする。更新は適用中の失敗復元だけを保証し、適用後 Undo は持たない

### 6. 更新・監視・パフォーマンス

#### Q28. インベントリをいつ再走査するか？

- A. View を開いた時と手動更新時
- B. ファイル監視で即時更新する
- C. 一定間隔で更新する
- D. A ＋ 限定的なファイル監視

**決定:** D — View を開いた時と手動更新 ＋ `Source` ホワイトリスト内だけのファイル監視。監視は View 表示中だけ動かし、非表示時に破棄する

#### Q29. CLI を使う一覧取得のキャッシュ時間はどうするか？

**決定:** B — TypeScript 拡張のメモリで約180秒。1コマンドごとに終了する Swift CLI には持たせない。明示的な更新・操作直後・View 非表示で破棄する

#### Q30. MCP プロセス状態の確認頻度はどうするか？

**決定:** B — 対象 View が表示されている間だけ 3 秒ポーリング

#### Q31. 拡張自身の更新通知は誰に任せるか？

**決定:** A — Cursor の拡張更新機構に任せる

### 7. 配布と公開範囲

#### Q32. 拡張をどこで配布するか？

**決定:** alpha / beta は GitHub Releases のみ。安定版は同じ VSIX を Open VSX へ公開してから GitHub Release を作成し、途中の失敗時は停止する

#### Q33. 拡張のソースコードを公開するか？

**決定:** A — MIT ライセンスで、最初の公開 VSIX より前に既存リポジトリを公開する

#### Q34. 拡張 ID とブランド名はどうするか？

**決定:** `agent-tool`（新名称で統一）

#### Q35. VS Code と Cursor で同じ VSIX を使うか？

**決定:** 初版は Cursor 専用 VSIX。VS Code 対応時に同一 VSIX か否かを判断

### 8. 品質保証と移行完了条件

#### Q36. 既存テストをどう扱うか？

**決定:** A — Swift Core の全テストを維持する。件数は増減するため完了条件には固定値を書かない

#### Q37. どの E2E 環境を必須にするか？

**決定:** 固定 URL と SHA-256 で取得した Cursor Stable を macOS CI の必須 E2E とする。定期 canary は設けない

#### Q38. 互換性テストで実 CLI をどこまで使うか？

**決定:** Ubuntu で TypeScript、macOS で Swift・Universal CLI・VSIX・Cursor E2E を全 PR で検証する

#### Q39. Mac App を廃止できる条件は何か？

**決定:** Phase 0 で main から削除する。Mac App の既存配布リポジトリはアーカイブし、追加リリースも移行告知もしない

#### Q40. テレメトリを導入するか？

**決定:** A — 一切導入しない

---

## Phase 0 のリネーム・整理

| 変更前 | 変更後 |
|---|---|
| 製品名・npm name | Agent Tool / `agent-tool` |
| 拡張 Publisher ID | `yuuki-sakai` |
| `ManageArmsCore` | `AgentToolCore` |
| `ManageArmsApp` | 削除。`AgentToolApp` へは変更しない |
| `manage-arms` リポジトリ・ローカルディレクトリ | 既存履歴のまま `agent-tool` へ変更 |
| 現行 Mac App の README / CHANGELOG | 削除し、Agent Tool 向けに新規作成 |
| `Scripts/` | `scripts/` へ変更し、Mac App 専用スクリプトを削除 |

TypeScript はリポジトリ直下の `src/`、`test/`、`media/`、`l10n/` に置く。
Swift は `Sources/AgentToolCore/`、`Sources/AgentToolCoreCLI/`、`Tests/AgentToolCoreTests/` に置く。

## Secondary Simulator と揃える運用

基本方針は [den0206/secondary-simulator](https://github.com/den0206/secondary-simulator) に揃え、
Agent Tool 固有のSwift CLI、永続registry、対応IDEの差だけを例外とする。

- Node 20、npm、`package-lock.json`、Node 標準 `node:test` を使う
- 最小依存・正確な版固定・`ignore-scripts=true`・第三者 Action の commit SHA 固定を守る
- `release/Ver_X.Y.Z`、英語の `[Unreleased]`、リリース時の版節切り出しを使う
- 初版は `0.1.0-alpha.1`。ブランチは `release/Ver_<semver>` とし、同版再ビルドはタグだけ `+N` にしてOpen VSXへ再公開しない
- Universal CLI は Developer ID 署名・公証を行わない。最初の公開前と、CLI・VSIX 組み立て・配布経路の変更時に、Cursor から入れた VSIX の初回起動を実機確認する
- README は英語・日本語を同期する

---

## 次のステップ

以下の文書を実装の正本とする：

1. [プロダクト要件](product-requirements.md)
2. [AgentToolCore CLI API](agent-tool-cli-api.md)
3. [データ・ロック・移行仕様](agent-tool-data-spec.md)
4. [UI 情報設計](agent-tool-ui-design.md)
5. [セキュリティ要件](agent-tool-security.md)
6. [テスト計画](agent-tool-test-plan.md)
7. [段階的リリース計画](agent-tool-release-plan.md)
