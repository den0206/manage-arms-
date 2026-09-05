# ManageArms

AI コーディングエージェント（Claude Code / Cursor / Codex / Gemini CLI）の周辺リソース —
**MCP・Skills・Subagents・Plugins** — を 1 つの GUI で横断管理する macOS アプリ。

同じリソースを、エージェントごとに、別々の場所へ、別々の書式で登録し直す作業をやめるためのもの。
設計の全体像は [DESIGN.md](DESIGN.md) を参照。

## できること

| | |
|---|---|
| **横断一覧** | 4 種別 × 4 エージェントのマトリクス。「非対応」と「未検出」を区別して表示する |
| **追加** | GitHub の URL を貼ると取得して中身を見せる。確認するまで何も入らない |
| **有効 / 無効** | 無効化は実体を退避するだけ。消さないので必ず戻せる |
| **更新** | `SKILL.md` の差分を見てから適用する。上流の方針転換に備えてピン留めもできる |
| **使用実績** | セッションログから最終使用日を集計。MCP は起動中のプロセスを実時間で表示する |
| **権限の掃除** | `permissions.allow` のマシン固有パス・プロジェクト間の重複を横断で削除する |

## 必要環境

- macOS 14 以降
- ビルドするなら Xcode 16 / Swift 6 以降

## インストール

[Releases](https://github.com/den0206/manage-arms/releases) から DMG をダウンロードし、
`ManageArms.app` をアプリケーションフォルダへドラッグする。

DMG から直接起動した場合は、起動時にアプリケーションフォルダへの移動を促す。

## ビルドと実行

Swift Package として構成されている（`.xcodeproj` は無い。Xcode で `Package.swift` を直接開ける）。

```bash
swift test                  # 単体テスト（241 件）
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
├── ManageArmsCore/     走査・追加・更新・集計・権限。テスト対象
│                       外部依存は Environment（構造体 + クロージャ）で注入する
└── ManageArms/         SwiftUI シェル（リソース / 権限 / エージェントの 3 画面）
Localization/           ja / en。キーは日本語文字列そのもの
Resources/              Info.plist / entitlements / アイコン
Scripts/                .app 組み立て・DMG・CHANGELOG 切り出し・不変条件の検査
docs/signing.md         Developer ID 署名と公証のセットアップ
```

## セキュリティ

- **App Sandbox 非対応**。他エージェントの設定を読み書きし CLI を起動するため
  → Mac App Store は選択肢にならず、Developer ID 署名 + 公証 + Hardened Runtime で直配布する
- **走査対象はホワイトリスト**。列挙にないパスは存在しても読まない
  （`~/.claude/projects` の 129 MB や `logs_*.sqlite` を踏まないため）
- **削除・移動してよい対象を限定**する。`WriteGuard` を通らない経路は CI が止める
- 設定ファイルの書き戻しは 3 か所のみ。MCP と Plugin の追加・削除は各 CLI に委譲する
  （`~/.claude.json` は 98 KB あり、直接書き戻すと実行中の Claude と競合して全状態を壊す）
- 権限の削除は `permissions` キーだけを書き換え、削除前の内容をバックアップする
- 依存サードパーティライブラリ ゼロ

## リリース

`main` から `release/Ver_X.Y.Z` ブランチを切って push すると、CI がテスト → 署名ビルド →
公証 → DMG → GitHub Release までを行う。手順とセットアップは [docs/signing.md](docs/signing.md)。

**署名・公証は必須。** シークレットが 1 つでも欠けていればワークフローは即座に停止し、
未署名の DMG は作られない。
