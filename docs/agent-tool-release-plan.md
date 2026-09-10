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
- [x] Tree ViewをScope → Agent → 種別 → Toolへ再構成し、一覧キャッシュを180秒で破棄
- [x] Toolをユーザー追加とエージェント同梱に分けて表示
- [x] Cursor Stable実機で初回起動とTree View表示を確認

| 機能               | 詳細                                                       |
| ------------------ | ---------------------------------------------------------- |
| `AgentToolCoreCLI` | `version`、`scan-path`、`inventory` を実装                 |
| TS 拡張            | Activity Bar、Tree View、PATH 検知結果を表示               |
| CLI 境界           | `child_process.spawn` と JSON stdin/stdout で接続          |
| テスト             | Swift Testing、Node `node:test`、固定 Cursor Stable の E2E |

### 完了条件

- CLI の3コマンドが偽ホームで動く
- Cursor の Activity Bar に Current Project と User Global が表示される
- Ubuntu のTypeScript検査とmacOSのSwift・Cursor E2Eが通る

## Phase 2 — alpha / beta

**目的**: 全対象機能を実装し、GitHub ReleasesでVSIXを配布する。

### 進捗

- [x] 管理対象のSkill / Subagentを有効化・無効化するCLIとTree View操作を追加
- [x] MCP稼働状態をView表示中だけ3秒ポーリングし、非表示時に破棄
- [x] MCP追加・削除の構造化CLI境界を追加
- [x] 公開GitHub URLからユーザー全体のSkillを追加するCLI境界を追加
- [x] Tree Viewから公開GitHub URLを入力してSkillを追加する導線を追加
- [x] 管理対象Skill / Subagentの削除と30秒Undoを追加
- [x] 更新の差分プレビューと、再取得・検証後の適用を追加
- [x] Cursor向けMCP追加・削除のTree View操作を追加
- [x] 旧ManageArmsのregistryと無効化中実体を確認後に移行する初回フローを追加
- [ ] Workspace Trust・Remote・旧Mac App起動中の操作拒否を全コマンドに適用
- [ ] Universal CLI、リソース計測、GitHub Releases配布を追加

| 機能     | 詳細                                                                                     |
| -------- | ---------------------------------------------------------------------------------------- |
| 管理操作 | `add`、`remove`、`rollback`、`toggle`、更新、MCP操作                                     |
| 初回移行 | 旧 `registry.json` を確認後に `globalStorageUri` へ移行                                  |
| 安全性   | WriteGuard、プロセス間ロック、Workspace Trust、Remote拒否、旧Mac App起動中の書き込み拒否 |
| 資源管理 | 上限・破棄条件の単体テスト、View非表示時の解放、RSS・保存容量計測                        |
| 配布物   | arm64とx86_64を結合した未署名Universal CLIをVSIXへ同梱                                   |

### 配布

- 初版は `0.1.0-alpha.1`
- `release/Ver_<semver>` ブランチ（初版は `release/Ver_0.1.0-alpha.1`）をpushしてGitHub Releaseを作る
- CHANGELOGの英語 `[Unreleased]` をリリース時に版節へ切り出す
- 公開済みの同版を再ビルドするときはタグだけ `+N` にし、VSIXの版は変えない
- 最初の公開VSIXより前に、このリポジトリをMITで公開する

### 完了条件

- [product-requirements.md](product-requirements.md) のβ版条件を満たす
- Cursor Stableで実CLIを使うE2Eが通る
- 最初の公開前と、CLI・VSIX組み立て・配布経路の変更時に、GitHubから取得したVSIXの初回CLI起動を実機確認する

## Phase 3 — 安定版

**目的**: 同じVSIXをOpen VSXとGitHub Releasesへ公開する。

### 公開順序

1. Node・Swiftの全検査、Cursor E2E、Universal Binary、資源上限を検証する
2. VSIXを一度だけ組み立て、SHA-256を記録する
3. `ovsx publish`でOpen VSXへ公開する
4. 同じVSIXをGitHub Releaseへ添付する

`OVSX_TOKEN`が無い場合やOpen VSXへの公開に失敗した場合は、GitHub Releaseを作らない。
途中でGitHub Releaseだけが失敗した場合は、同じ成果物でGitHub側だけを再実行する。
再実行では記録済みSHA-256と一致するワークフロー成果物を使い、Open VSXへ再公開しない。

## CI・依存管理

- Node 20、npm、`package-lock.json`、Node標準 `node:test` を使う
- UbuntuでTypeScriptの型検査・単体テスト、macOSでSwift・Universal CLI・VSIX・Cursor E2Eを全PRで実行する
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
| CLI stdout / stderr      | 各2 MB                       |
| ダウンロード             | 50 MB                        |
| 展開後                   | 200 MB                       |
| 単一ファイル             | 20 MB                        |

上限と破棄条件は単体テストで守り、リリース前にRSSとAgent Tool自身の保存容量を計測する。
