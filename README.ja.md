# ManageArms

*[English](README.md) · 日本語*

AI コーディングエージェント（Claude Code / Cursor / Codex / Gemini CLI）の周辺リソース —
**MCP・Skills・Subagents・Plugins** — を 1 つの GUI で横断管理する macOS アプリ。

同じリソースを、エージェントごとに、別々の場所へ、別々の書式で登録し直す作業をやめるためのもの。
設計の全体像は [DESIGN.md](DESIGN.md) を参照。

## できること

| | |
|---|---|
| **エージェント別の一覧** | サイドバーでエージェントを選ぶと、そのエージェントが持っているものだけが並ぶ。**自分で入れたものを本体に出し（CLI で入れた MCP・プラグインも管理元を添えて並べる）、エージェント同梱のものは畳んでおく** |
| **追加** | SkillsはGitHubから内容を確認。MCPはJSON・接続先URL・起動コマンド、Pluginは名前と配布元を指定し、Agentを選んで追加 |
| **有効 / 無効 / 削除** | アプリ管理の共有Skillは切替可能。既存のユーザーToolも配置場所・Agentを指定して削除できる。ファイルはゴミ箱へ、MCP/Pluginは各管理元で登録解除 |
| **同梱の保護** | 既知の同梱Skill領域と保護メタデータのあるToolは変更不可。Plugin配下へのリンクも保護 |
| **更新** | `SKILL.md` の差分を見てから適用する。上流の方針転換に備えてピン留めもできる |
| **スコープ** | 「ユーザー全体」「プロジェクトごと」「エージェント同梱」をタブで切り替える。重複は両方に警告し、プロジェクト側だけ一括削除できる |
| **使用実績** | Claude Code・Codex・Cursor のセッションログから最終使用日を集計。表示中は3秒ごとにMCPプロセスを確認。実際のTool呼び出し中とは区別 |
| **ブラウザ検知** | 既定 ON。ブラウザで Skill・Plugin・Subagent のページを開くと、メニューバーアイコンを緑にして追加を提案する（ページから離れれば元に戻る）（URL を貼らずに済み、システム通知は使わない）。出す前に `raw.githubusercontent.com` で実在を確かめ、URL は保存しない |
| **外観** | 設定でライト・ダーク・システム追従を切り替える（既定はシステム追従） |

## 必要環境

- macOS 26 以降
- ビルドするなら Xcode 26 / Swift 6.2 以降

## インストール

[Releases](https://github.com/den0206/manage-arms-releases/releases/latest) から DMG をダウンロードし、
`ManageArms.app` をアプリケーションフォルダへドラッグする。

DMG から直接起動した場合は、起動時にアプリケーションフォルダへの移動を促す。

## ビルドと実行

Swift Package として構成されている（`.xcodeproj` は無い。Xcode で `Package.swift` を直接開ける）。

```bash
swift test                  # 全単体テスト（MANUAL=1 で実CLI確認が加わる）
swift build                 # コンパイル確認

# 配布形態は「手組みの .app バンドル」。build-app.sh が組み立て + 署名まで行う。
CONFIG=debug UNIVERSAL=0 ./Scripts/build-app.sh   # 開発用（高速・ネイティブ arch）
open ".build/debug/ManageArms Debug.app"
```

`swift run ManageArms` でも起動はするが、`Bundle.main` が Info.plist・アイコン・
ローカライズを解決できない。**`.app` を組んで起動すること。**
GUI 起動時の `PATH` は Finder 経由だと `/usr/bin:/bin:/usr/sbin:/sbin` しか無く、
`claude` / `codex` / `gemini` が 1 つも見つからない（`ShellPath` がログインシェルから復元する）。
この挙動は `.app` にして初めて再現する。

### VS Code / Cursor で F5 起動

`.vscode/{launch,tasks}.json` を同梱。**F5** でデバッグビルドの `.app` を組み立てて起動する
（要 CodeLLDB 拡張）。デバッガ拡張が無くても **Cmd+Shift+B** で「ビルドして起動」できる。
「Run ManageArms Debug.app (English)」を選ぶと英語 UI で起動する。

**デバッグビルドは別アプリとして組み立てる**（`com.yuukisakai.manage-arms.debug` /
`ManageArms Debug.app`）。保存先が `~/Library/Application Support/ManageArms Debug` に
分かれるため、開発中のリビルドがインストール済みリリース版の `registry.json` を壊さない。

> ただし `~/.agents/skills` と `~/.claude/skills` は home 基準の共有ルートなので分離できない。
> **デバッグ版でもスキルの有効化・無効化は実環境に効く。**

## プロジェクト構成

```
Sources/
├── ManageArmsCore/     走査・追加・更新・集計。テスト対象
│                       外部依存は Environment（構造体 + クロージャ）で注入する
└── ManageArms/         SwiftUI シェル（ホーム / エージェントごとの一覧 / 設定）
Localization/           ja / en。キーは日本語文字列そのもの
Resources/              Info.plist / entitlements / アイコン
Scripts/                .app 組み立て・DMG・CHANGELOG 切り出し・不変条件の検査
docs/                   Agent Tool への移行・実装仕様
```

## セキュリティ

- **App Sandbox 非対応**。他エージェントの設定を読み書きし CLI を起動するため
  → Mac App Store は選択肢にならず、Developer ID 署名 + 公証 + Hardened Runtime で直配布する
- **走査対象はホワイトリスト**。列挙にないパスは存在しても読まない
  （`~/.claude/projects` の 129 MB や `logs_*.sqlite` を踏まないため）
- **削除・移動してよい対象を限定**する。`WriteGuard` を通らない経路は CI が止める
- 設定ファイルの書き戻しは 2 か所のみ。MCP と Plugin の追加・削除は各 CLI に委譲する
  （`~/.claude.json` は 98 KB あり、直接書き戻すと実行中の Claude と競合して全状態を壊す）
- **自分の永続ファイルは 1 つだけ。** キャッシュディレクトリを持たず、`URLSession` は
  `.ephemeral`、一時展開は OS の一時領域で完結させる
- **ブラウザ検知は範囲が最小で、OFF にできる。** 最初にブラウザが前面へ来た時点で
  ブラウザ制御の許可を求め、拒否されたら自分で止まる。動くのはブラウザが前面の間だけで、
  通知の許可は求めない（見つけたものはメニューバーのアイコンを緑にして知らせる）。
  URL は `github.com` / `skills.sh` かどうかを見たら捨て、保存もログ出力もしない
- **常駐してもアイドル中は何も持たない。** ウィンドウを閉じた時点で一覧をメモリから捨て、
  次に開くまで走査しない
- 依存サードパーティライブラリ ゼロ

## リリース

`main` から `release/Ver_X.Y.Z` ブランチを切って push すると、CI がテスト → 署名ビルド →
公証 → DMG → GitHub Release までを行う。Mac App 廃止まで必要な手順は release workflow 内に残す。

**Release の公開先は別の公開リポジトリ**
[den0206/manage-arms-releases](https://github.com/den0206/manage-arms-releases)。
ソースは Private のまま、ダウンロード先だけを公開する。利用者向けの README（英語・日本語）・
変更履歴・Issue テンプレートもそちらにあり、Release の公開を受けて最新版の表示が自動で追従する。

**署名・公証は必須。** シークレットが 1 つでも欠けていればワークフローは即座に停止し、
未署名の DMG は作られない。既にあるタグは上書きせず、`Ver_X.Y.Z+N` として公開する。

## 互換性の検証と対応範囲

`Scripts/check-agent-compatibility.sh claude`（または `codex` / `gemini`）は、
一時領域に最新版CLIを取得し、認証情報を引き継がない一時ホームでMCPの追加・読み取り・削除、
引数・環境変数・HTTPヘッダの保持、PluginのCLI契約を確認します。第2引数で版を指定できます。
CIは手動実行（workflow_dispatch）で同じスクリプトを実行します。通常の `swift test` は実CLIのテストをスキップします。

MCP/Pluginの新規追加はユーザー全体スコープです。Cursor Pluginの管理、実際のTool呼び出し
イベントの検知、未知の同梱形式の自動判定には未対応です。HTTP MCPをローカルのプロセスだけで
停止と判定しません。明示的なプロジェクト追加はClaude形式の設定を対象とします。
Plugin本体のインストールとGUIの操作は、互換性テストとは別に実機確認が必要です。
詳細は [設計15章](DESIGN.md#15-既存toolの管理と互換性検証2026-09-06) を参照してください。
