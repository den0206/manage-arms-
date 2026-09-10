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

| 作業 | 詳細 |
|---|---|
| リポジトリ名 | GitHub とローカルディレクトリを `manage-arms` から `agent-tool` へ変更。新規リポジトリは作らない |
| Swift Core | `ManageArmsCore` を `AgentToolCore` へ変更し、既存ロジックとテストを維持 |
| Mac App | `Sources/ManageArms/`、Resources、Localization、DMG・署名・公証処理、`DESIGN.md` を main から削除 |
| 旧配布 | `manage-arms-releases` をアーカイブ。追加リリースと移行告知は行わない |
| 拡張配置 | ルートに `package.json`、`src/`、`test/`、`media/`、`l10n/` を置く |
| スクリプト | `Scripts/` を `scripts/` へ変更し、Swift・Node共通の入口にする |
| 文書 | README 日英版と CHANGELOG を Agent Tool 向けに新規作成。旧履歴は Git に残す |
| Publisher | `yuuki-sakai` を `package.json` に設定 |

### 完了条件

- Mac App 専用コード、ビルド、配布、署名、公証処理が main に残っていない
- `swift build && swift test` と不変条件検査が通る
- Node 20、npm、`package-lock.json`、`ignore-scripts=true` の土台がある
- 旧 ManageArms データの移行元パスだけが仕様と移行コードに残る

## Phase 1 — プロトタイプ

**目的**: AgentToolCore CLI と Cursor 拡張の基本疎通を確認する。

| 機能 | 詳細 |
|---|---|
| `AgentToolCoreCLI` | `version`、`scan-path`、`inventory` を実装 |
| TS 拡張 | Activity Bar、Tree View、PATH 検知結果を表示 |
| CLI 境界 | `child_process.spawn` と JSON stdin/stdout で接続 |
| テスト | Swift Testing、Node `node:test`、固定 Cursor Stable の E2E |

### 完了条件

- CLI の3コマンドが偽ホームで動く
- Cursor の Activity Bar に Current Project と User Global が表示される
- Ubuntu のTypeScript検査とmacOSのSwift・Cursor E2Eが通る

## Phase 2 — alpha / beta

**目的**: 全対象機能を実装し、GitHub ReleasesでVSIXを配布する。

| 機能 | 詳細 |
|---|---|
| 管理操作 | `add`、`remove`、`rollback`、`toggle`、更新、MCP操作 |
| 初回移行 | 旧 `registry.json` を確認後に `globalStorageUri` へ移行 |
| 安全性 | WriteGuard、プロセス間ロック、Workspace Trust、Remote拒否、旧Mac App起動中の書き込み拒否 |
| 資源管理 | 上限・破棄条件の単体テスト、View非表示時の解放、RSS・保存容量計測 |
| 配布物 | arm64とx86_64を結合した未署名Universal CLIをVSIXへ同梱 |

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

| 指標 | 上限 |
|---|---|
| 一覧表示 | キャッシュヒット時300 ms未満 |
| View非表示時のメモリ増分 | 65 MB未満 |
| VSIX | 20 MB未満 |
| CLI stdout / stderr | 各2 MB |
| ダウンロード | 50 MB |
| 展開後 | 200 MB |
| 単一ファイル | 20 MB |

上限と破棄条件は単体テストで守り、リリース前にRSSとAgent Tool自身の保存容量を計測する。
