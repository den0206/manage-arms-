# Agent Tool — 段階的リリース計画

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> リリース条件は [product-requirements.md](product-requirements.md) を参照。

## 概要

```
Phase 0: Agent Tool へ改名・Mac App 撤去
    ↓
Phase 1: プロトタイプ
    ↓
Phase 2: alpha / beta（GitHub Releases）
    ↓
Phase 2.5: TypeScript 統一・クロスプラットフォーム化
    ↓
Phase 3: 安定版（Open VSX + GitHub Releases）
```

## Phase 0 — 改名・整理

**目的**: 既存リポジトリをそのまま Agent Tool の開発基盤へ切り替える。

### 進捗

- [x] Secondary Simulatorとの共通方針とAgent Tool固有の例外を決定
- [x] Phase 0の対象資産と参照箇所を棚卸し
- [x] 設計文書とIDE向け作業規則を更新
- [x] Mac App専用コード・資産・配布処理を削除
- [x] Core、テスト、スクリプトを新名称へ変更
- [x] ルートnpm構成とCIを作成
- [x] READMEとCHANGELOGをAgent Tool向けに初期化
- [x] 全検査を通す
- [x] GitHubリポジトリを`agent-tool`へ変更し、旧配布リポジトリをアーカイブ
- [ ] ローカルディレクトリを`agent-tool`へ変更

| 作業         | 詳細                                                                                              |
| ------------ | ------------------------------------------------------------------------------------------------- |
| リポジトリ名 | GitHub とローカルディレクトリを `manage-arms` から `agent-tool` へ変更。新規リポジトリは作らない  |
| Swift Core   | `ManageArmsCore` を `AgentToolCore` へ変更し、既存ロジックとテストを維持                          |
| Mac App      | `Sources/ManageArms/`、Resources、Localization、DMG・署名・公証処理、`DESIGN.md` を main から削除 |
| 旧配布       | `manage-arms-releases` をアーカイブ。追加リリースと移行告知は行わない                             |
| 拡張配置     | ルートに `package.json`、`src/`、`test/`、`media/`、`l10n/` を置く                                |
| スクリプト   | `Scripts/` を `scripts/` へ変更し、Swift・Node共通の入口にする                                    |
| 文書         | README 日英版と CHANGELOG を Agent Tool 向けに新規作成。旧履歴は Git に残す                       |
| Publisher    | `yuuki-sakai` を `package.json` に設定                                                            |

### 完了条件

- Mac App 専用コード、ビルド、配布、署名、公証処理が main に残っていない
- `swift build && swift test` と不変条件検査が通る
- Node 20、npm、`package-lock.json`、`ignore-scripts=true` の土台がある
- 旧 ManageArms データの移行元パスだけが仕様と移行コードに残る

## Phase 1 — プロトタイプ

**目的**: AgentToolCore CLI と Cursor 拡張の基本疎通を確認する。

### 進捗

- [x] `AgentToolCoreCLI` ターゲットを追加し、`version` / `scan-path` / `inventory` の JSON 応答を実装
- [x] 拡張の Activity Bar / Inventory View と CLI 呼び出し境界を追加
- [x] CLI を VSIX に同梱
- [x] Node `node:test` を追加
- [x] VSIX展開後の同梱CLIスモーク検査を追加
- [x] Cursor E2E実行入口を追加（`CURSOR_PATH`指定時）
- [x] 拡張のCLI出力上限（stdout / stderr 各2 MB）と180秒タイムアウトを実装
- [x] Cursor CLIで隔離ディレクトリにVSIXをインストールし、拡張IDの認識を確認
- [x] DashboardをCurrent Project / User Global・種別で絞り込み、一覧キャッシュを180秒で破棄
- [x] DashboardでToolをYour toolsとBundledに分けて表示し、カードから操作を開始できるようにした
- [x] Cursor Stable実機で初回起動とDashboard表示を確認

| 機能               | 詳細                                                       |
| ------------------ | ---------------------------------------------------------- |
| `AgentToolCoreCLI` | `version`、`scan-path`、`inventory` を実装                 |
| TS 拡張            | Activity Bar、Dashboard、PATH 検知結果を表示               |
| CLI 境界           | `child_process.spawn` と JSON stdin/stdout で接続          |
| テスト             | Swift Testing、Node `node:test`、固定 Cursor Stable の E2E |

### 完了条件

- CLI の3コマンドが偽ホームで動く
- Cursor の Activity Bar にDashboardが表示され、Current Project と User Globalで絞り込める
- Ubuntu のTypeScript検査とmacOSのSwift・Cursor E2Eが通る

## Phase 2 — alpha / beta

**目的**: 全対象機能を実装し、GitHub ReleasesでVSIXを配布する。

### 進捗

- [x] 管理対象のSkill / Subagentを有効化・無効化するCLIとDashboard操作を追加
- [x] Dashboardの一覧キャッシュを非表示時に破棄
- [x] MCP稼働状態をDashboard表示中だけポーリングして表示
- [x] MCP追加・削除の構造化CLI境界を追加
- [x] 公開GitHub URLからユーザー全体のSkillを追加するCLI境界を追加
- [x] Dashboardから公開GitHub URLを入力してSkillを追加する導線を追加
- [x] 管理対象Skill / Subagentの削除を追加（30秒UndoはD-5で廃止し、確認ダイアログに一本化）
- [x] 更新の差分プレビューと、再取得・検証後の適用を追加
- [x] Cursor向けMCP追加・削除のDashboard操作を追加
- [x] 旧ManageArmsのregistryと無効化中実体を確認後に移行する初回フローを追加
- [x] Workspace Trust・Remote・旧Mac App起動中の操作拒否を全コマンドに適用
- [ ] リソース計測とGitHub Releases配布を追加（Universal CLI同梱はPhase 2.5で廃止）

| 機能     | 詳細                                                                                     |
| -------- | ---------------------------------------------------------------------------------------- |
| 管理操作 | `add`、`remove`、`rollback`、`toggle`、更新、MCP操作                                     |
| 初回移行 | 旧 `registry.json` を確認後に `globalStorageUri` へ移行                                  |
| 安全性   | WriteGuard、プロセス間ロック、Workspace Trust、Remote拒否、旧Mac App起動中の書き込み拒否 |
| 資源管理 | 上限・破棄条件の単体テスト、View非表示時の解放、RSS・保存容量計測                        |
| 配布物   | VSIX単体（Universal CLI同梱はPhase 2.5で廃止）                                           |

### 配布

- 初版は `0.1.0-alpha.1`
- `release/Ver_<semver>` ブランチ（初版は `release/Ver_0.1.0-alpha.1`）をpushしてGitHub Releaseを作る
- CHANGELOGの英語 `[Unreleased]` をリリース時に版節へ切り出す
- 公開済みの同版を再ビルドするときはタグだけ `+N` にし、VSIXの版は変えない
- 最初の公開VSIXより前に、このリポジトリをMITで公開する

### 完了条件

- [product-requirements.md](product-requirements.md) のβ版条件を満たす
- Cursor Stableで実モジュールを使うE2Eが通る
- 最初の公開前と、VSIX組み立て・配布経路の変更時に、GitHubから取得したVSIXの初回起動を実機確認する

## Phase 2.5 — TypeScript統一・クロスプラットフォーム化

**目的**: Swift CoreとCLIをTypeScriptへ移し、macOS / Linux / Windowsで全機能を提供する（設計決定 D-1〜D-10）。

**規模**: Swift実装 約4,900行、Swiftテスト 約5,300行。動作中のPhase 2機能を止めないため、
D-10の「TypeScript先行実装 → Swift削除」の順で進め、5が終わるまでSwiftを消さない。

### 進捗

- [x] 1. 基盤 — `writeGuard.ts`、`registry.ts`（O_EXCLロック）、走査ホワイトリスト（`source.ts`）とテスト
  （`agent.ts`・`env.ts`・`errors.ts`・`projectScan.ts`の純粋部分を含む。`check-invariants.sh`のD-9検査も先行して追加した。`assertUserArtifact`は`projectScan`が要るので2で入れる）
- [x] 2. 走査 — frontmatter、Skill / Subagent / MCP / Plugin スキャナ、`inventory`
  （`inventory`は仕様の`InventoryItem`だけを組み立てる。旧`ResourceRow`の容量・削除コマンド・使用実績はMac App向けなので移さない）
- [x] 3. 取得・適用 — `fetcher.ts`（`fetch` + zip展開）、`installer.ts`、`updater.ts`、`skillManager.ts`
  （`github.ts`を含む。実書き込みは`writeGuard.ts`の関数だけに置き、`fetcher.ts`は`./env`を読み込まないことでOS一時領域から出られないようにした）
- [x] 4. 周辺 — `processScanner.ts`（`ps` / `Get-CimInstance`）、PATH検知、貼り付け解析、`migrate`
  （使用実績の走査は移さない。新しい`InventoryItem`に最終使用日が無く、読む相手がいないため）
- [x] 5. 拡張の呼び出し口を`child_process.spawn`から直接のモジュール呼び出しへ差し替え
  （`agentTool.ts`が仕様のモジュールAPIの入口。`src/cli.ts`は削除）
- [x] 6. Windowsのリンク層（junction / hardlink）を実装し、3 OSのCIを整える
- [x] 7. Swift一式・`Package.swift`・CLI依存スクリプトを削除し、`check-invariants.sh`をTS版へ書き換え
- [x] 8. `CLAUDE.md`の完了の定義・不変条件をTypeScript版へ差し替え

| 作業           | 詳細                                                                                     |
| -------------- | ---------------------------------------------------------------------------------------- |
| 削除           | `Sources/`、`Tests/`、`Package.swift`、`scripts/build-cli.sh`、`scripts/test-vsix-cli.sh` |
| リンク方式     | macOS / Linuxはsymlink、WindowsはjunctionとhardlinkでD-4を実装                            |
| MCP稼働判定    | 全プロセスを1回取得し、登録済みMCP定義と親PIDで突き合わせる（D-8）                        |
| 書き込み経路   | `writeGuard.ts` / `registry.ts` / `mcpScanner.ts`の3経路に限定し、静的検査で守る（D-9）   |
| Undo           | ゴミ箱移動と30秒Undoを削除し、確認ダイアログへ一本化（D-5）                               |
| CI             | Ubuntu・macOS・Windowsで同じテストを回す。Cursor E2EはmacOSのみ                           |

### 完了条件

- [x] Swift、`Package.swift`、CLI同梱処理がmainに残っていない
- [x] `npm run check`（型検査・テスト・不変条件検査）がローカルで通る
- [ ] 3 OSのCIが緑になる（Windowsランナーでの初回実行を待つ）
- [ ] Windows実機でjunction / hardlinkによる追加・有効化・更新・削除が動く
- [x] VSIXにバイナリを同梱しない状態でCursor E2Eが通る（112 KB / 上限20 MB）

## Phase 3 — 安定版

**目的**: 同じVSIXをOpen VSXとGitHub Releasesへ公開する。

### 公開順序

1. 3 OSでのNodeの全検査、Cursor E2E、資源上限を検証する
2. VSIXを一度だけ組み立て、SHA-256を記録する
3. `ovsx publish`でOpen VSXへ公開する
4. 同じVSIXをGitHub Releaseへ添付する

`OVSX_TOKEN`が無い場合やOpen VSXへの公開に失敗した場合は、GitHub Releaseを作らない。
途中でGitHub Releaseだけが失敗した場合は、同じ成果物でGitHub側だけを再実行する。
再実行では記録済みSHA-256と一致するワークフロー成果物を使い、Open VSXへ再公開しない。

## CI・依存管理

- Node 20、npm、`package-lock.json`、Node標準 `node:test` を使う
- Ubuntu・Windowsで型検査と単体テスト、macOSで単体テスト・VSIX・Cursor E2Eを全PRで実行する
- 定期canaryは設けない
- 依存は必要最小限かつ正確な版に固定し、`ignore-scripts=true`を使う
- 第三者GitHub Actionsはcommit SHAへ固定し、Dependabotで更新する
- Cursor Stableの取得URLとSHA-256を固定し、`@vscode/test-electron`へ実行ファイルを明示する

## 資源・配布ゲート

| 指標                     | 上限                         |
| ------------------------ | ---------------------------- |
| 一覧表示                 | キャッシュヒット時300 ms未満 |
| View非表示時のメモリ増分 | 65 MB未満                    |
| VSIX                     | 20 MB未満                    |
| 外部コマンドのstdout / stderr | 各2 MB                  |
| ダウンロード             | 50 MB                        |
| 展開後                   | 200 MB                       |
| 単一ファイル             | 20 MB                        |

上限と破棄条件は単体テストで守り、リリース前にRSSとAgent Tool自身の保存容量を計測する。
