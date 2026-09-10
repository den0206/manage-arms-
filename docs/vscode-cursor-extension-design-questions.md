# Agent Tool — Cursor 拡張版 設計決定記録

## 目的

ManageArms の機能を Cursor 拡張（Agent Tool）へ移行するにあたり、実装前に決めた事項の記録。
質問票形式から始まり、グリリングセッション（2026-09-10）で全項目を決定した。

## 追加要件（グリリングセッションで確定）

- **製品名を「Agent Tool」にリネーム**（コード・リポジトリ・ドキュメントすべて含む）
  - `ManageArmsCore` → `AgentToolCore`
- **拡張内の PATH を検知して使用中の Tool/Skill を前面表示**
  - ログインシェルの PATH から AI エージェント CLI（claude / cursor / codex / gemini）の有無とバージョンを表示
- **ユーザー全体（`~/.claude/`）と各 PJ（`.claude/`）の Tool を常に参照可能**
  - Tree View をセクション分割し、Current Project と User Global を常時表示
- **Mac App は機能同等に達した時点で削除**

## 現時点で分かっている制約

- MCP・Skill・Subagent・Plugin の管理機能は、Cursor 拡張へ概ね移行できる。
- macOS メニューバー常駐と IDE 終了後のブラウザ検知は廃止する。
- ローカルのホームディレクトリと CLI を扱うため、`extensionKind: ["ui"]` でローカル限定とする。
- Remote SSH・Dev Container・Codespaces では非対応として明示的にエラー表示する。
- 現行の `AgentToolCore`（旧 ManageArmsCore）・WriteGuard・375 件のテストは移行資産として維持する。

---

## A. プロトタイプ着手前に決める質問

### 1. 製品の位置づけ

#### Q1. 拡張版の最終目的は何か？

- A. Mac App を完全に置き換える
- B. Mac App と拡張版を恒久的に併用する
- C. 当初は併用し、十分な機能が揃った後に Mac App 廃止を判断する

**決定:** A — Mac App は拡張版が機能同等に達した時点で削除する

#### Q2. 最初のリリースで対象にするエディタはどれか？

- A. VS Code のみ
- B. Cursor のみ
- C. VS Code と Cursor の両方

**決定:** B — Cursor のみ。VS Code 対応は後続フェーズ

#### Q3. 対応OSはどうするか？

- A. macOS のみ
- B. macOS を先行し、後から Windows/Linux を検討する
- C. 初版から macOS/Windows/Linux に対応する

**決定:** B — 拡張 UI は Cursor が動く OS はすべて対象。AgentToolCore Swift CLI は macOS 先行

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

**決定:** A — `AgentToolCore`（旧 ManageArmsCore）に Swift CLI エントリポイントを新規作成し、TypeScript 拡張から呼ぶ。WriteGuard・375 テストを維持

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

**決定:** 移行期間は許容するが、書き込みは拡張版のみ。Mac App は機能同等後に削除

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
      Skills
      Subagents
      MCP Servers
▾ 👤 User Global  (~/.claude/)
      Skills
      Subagents
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

**決定:** B — メモリ上で直近だけ保持。終了時に破棄し、シークレットを必ずマスクする

#### Q25. GitHub 取得時の認証方法はどうするか？

**決定:** A — 公開リポジトリのみ・未認証。非公開リポジトリ対応時に VS Code GitHub Authentication API を追加

#### Q26. 現行の WriteGuard 不変条件をどこまで維持するか？

**決定:** A — 現行と同等を必須。書き込み許可ルート・symlink・設定ファイル・SQLite 拒否を維持。AgentToolCore Swift CLI 内に保持

#### Q27. 削除後の復旧方法をどうするか？

- A. OS のゴミ箱だけに任せる
- B. 操作単位のロールバック ＋ ゴミ箱
- C. 独自バックアップを持つ

**決定:** B — 操作単位のロールバック ＋ OS ゴミ箱

### 6. 更新・監視・パフォーマンス

#### Q28. インベントリをいつ再走査するか？

- A. View を開いた時と手動更新時
- B. ファイル監視で即時更新する
- C. 一定間隔で更新する
- D. A ＋ 限定的なファイル監視

**決定:** D — View を開いた時と手動更新 ＋ 設定ファイル（`~/.claude/`・`.claude/` 配下）のみファイル監視

#### Q29. CLI を使う一覧取得のキャッシュ時間はどうするか？

**決定:** B — 約 180 秒。明示的な更新と操作直後は無効化する

#### Q30. MCP プロセス状態の確認頻度はどうするか？

**決定:** B — 対象 View が表示されている間だけ 3 秒ポーリング

#### Q31. 拡張自身の更新通知は誰に任せるか？

**決定:** A — Cursor の拡張更新機構に任せる

### 7. 配布と公開範囲

#### Q32. 拡張をどこで配布するか？

**決定:** GitHub Releases（VSIX）を先行。安定後に Cursor Marketplace へ展開

#### Q33. 拡張のソースコードを公開するか？

**決定:** A — 全公開（MIT ライセンス）

#### Q34. 拡張 ID とブランド名はどうするか？

**決定:** `agent-tool`（新名称で統一）

#### Q35. VS Code と Cursor で同じ VSIX を使うか？

**決定:** 初版は Cursor 専用 VSIX。VS Code 対応時に同一 VSIX か否かを判断

### 8. 品質保証と移行完了条件

#### Q36. 既存 375 テストをどう扱うか？

**決定:** A — AgentToolCore Swift CLI 方式でそのまま維持する

#### Q37. どの E2E 環境を必須にするか？

**決定:** Cursor Stable を必須。安定後に Cursor Insiders も定期実行

#### Q38. 互換性テストで実 CLI をどこまで使うか？

**決定:** B — PR はモック、日次で実 CLI

#### Q39. Mac App を廃止できる条件は何か？

**決定:** 拡張版が Mac App の管理機能と同等になった時点で削除

#### Q40. テレメトリを導入するか？

**決定:** A — 一切導入しない

---

## リネーム計画

| 変更前 | 変更後 |
|---|---|
| ManageArms（製品名） | Agent Tool |
| ManageArmsCore（モジュール名） | AgentToolCore |
| ManageArmsApp（エントリポイント） | AgentToolApp |
| manage-arms（リポジトリ名・npm name） | agent-tool |
| ManageArms（Publisher ID） | agent-tool |
| README / CHANGELOG / ドキュメント類 | Agent Tool に統一 |

リネームは Mac App 削除と同時に実施する。コード・ファイル名・ドキュメントすべてを一括で変更する。

---

## 次のステップ

以下のドキュメントへ落とし込む（優先順）：

1. **プロダクト要件** — 対象機能／対象外機能の確定リスト
2. **AgentToolCore CLI API 仕様** — コマンド一覧・JSON スキーマ・エラーコード
3. **データ・ロック・移行仕様** — globalStorageUri 構造・ロックファイル方式・初回移行フロー
4. **UI 情報設計** — Tree View 詳細・Quick Pick フロー・PATH 検出表示
5. **セキュリティ要件** — WriteGuard 移植仕様・未信頼ワークスペース動作
6. **テスト計画** — Swift テスト維持方針・E2E Cursor Stable セットアップ
7. **段階的リリース計画** — Mac App 並走期間・機能同等条件・削除手順
