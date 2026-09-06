# CLAUDE.md — ManageArms 作業ガイド

AI コーディングエージェントの周辺リソース（MCP / Skills / Subagents / Plugins）を
横断管理する macOS アプリ。Swift 6 / SwiftUI / **依存ライブラリゼロ**。

このファイルは「作業の進め方」を定める。**機能の詳細設計は [DESIGN.md](DESIGN.md) が正**。
設計と矛盾する実装をしそうになったら、まず DESIGN.md の該当章を読むこと。

| ファイル | 内容 |
|---|---|
| `DESIGN.md` | 設計の正本。中核の判断（3 章）・データモデル・スコープ・テスト戦略・実測データ |
| `AGENTS.md` | Agent向けの入口。内容はこの `CLAUDE.md` を参照し、ルールを複製しない |
| `README.md` / `README.ja.md` | 利用者・新規参加者向けの入口（英語が既定、日本語は対訳）。**片方だけ直さない** |
| `.claude/commands/` | `/commit-by-feature`・`/review-for-merge`（このリポジトリ用のスラッシュコマンド） |
| `docs/signing.md` | Developer ID 署名・公証のセットアップ手順と罠（人間が 1 回だけやる作業） |
| `CHANGELOG.md` | 公開 Release 本文の出所。**英語**・Keep a Changelog |

## 完了の定義

実装したら毎回これを通す。`main` 向け PR では `.github/workflows/ci.yml` が同じものを回す。

```bash
swift build && swift test
./Scripts/check-invariants.sh                                              # 不変条件
./Scripts/release-changelog.sh --check && ./Scripts/test-release-changelog.sh
CONFIG=debug UNIVERSAL=0 ./Scripts/build-app.sh                            # .app が組めること
```

**CI に別のロジックを持たせない。** CI は上と同じスクリプトを呼ぶだけにする。
片方だけ直すと「手元では通るのに CI で落ちる／その逆」が起きる。

## 絶対に守る不変条件

`Scripts/check-invariants.sh` が機械的に検査する。載せるのは
**「破れると実ユーザーのデータが壊れる」もの**だけ。網羅性より、
赤くなったときに必ず本物のバグである状態を優先する。

1. **設定ファイルの書き込みは 3 か所だけ** — `PermissionWriter`（`permissions` キーのみ）/
   `Registry`（自分の `registry.json`）/ `MCPScanner`（`~/.cursor/mcp.json`）。
   ここが増えると「書き込みは各 CLI に委譲する」という中核の判断（DESIGN 3.1）が崩れ、
   実行中の Claude と競合してユーザーの全状態を壊しうる。
2. **削除・移動・symlink 作成は `WriteGuard` を通る経路だけ** — Skill/Subagent の
   共通 lifecycle を持つ `SkillManager` と `Updater` は必ず `WriteGuard.assertMutable` を呼ぶ。
   `Fetcher` / `Installer` は一時ディレクトリのみ、`InstallLocationGuard` は
   直前に自分が `/Applications` へ作ったバンドルのみ。
   既存ユーザーToolの削除は `WriteGuard.assertUserArtifact` で既知ルート直下を検証する。
   新しいファイルで無防備に `removeItem` を書くと `~/.claude` や `~/.agents` を消しうる。
3. **`ja` と `en` のキー集合が一致していること** — 片方に足し忘れると、
   その文言だけ日本語のまま英語 UI に出る。
4. **走査対象はホワイトリスト**（DESIGN 3.4）。除外リスト方式にしない。
   `Source` の列挙に無いパスは存在しても読まない。`projects` / `sessions` は
   使用実績の集計からのみ、`usageLog` ケース経由で読む。
5. **常駐中に抱えない・キャッシュしない**（DESIGN 3.5 / 15）。メニューバー常駐は既定 ON
   だが、ウィンドウを閉じたら一覧はメモリから捨てる（`AppModel.releaseForBackground`）。
   設定はアクティブ化時に再走査し、ウィンドウ表示中だけ起動状態を3秒ごとに取得する。
   永続ファイルは `registry.json` 1 つだけ。

## ストレージ・メモリの規律（徹底する）

**リソース管理アプリが自分でディスクを汚したら本末転倒。** DESIGN 9 章が正本。
目標値（`footprint -p` の phys_footprint で見る）: 常駐時 65 MB ／表示中 < 80 MB ／
アプリ自身のディスク使用 < 5 MB ／起動〜一覧表示 < 300 ms。

- **無駄なファイルを作らない。** 迷ったら作らない。恒久ファイルを増やす前に、
  「毎回計算し直せないか」「一時領域で完結しないか」を先に潰す。
  永続化してよいのは `registry.json` **1 つだけ**（DESIGN 4.1）。
  ログファイル・スナップショット・「あとで使うかもしれない」中間生成物は置かない。
- **キャッシュディレクトリを持たない。** 一時展開は `FileManager.temporaryDirectory` で
  完結させ、OS に回収させる。自前の掃除機能を持たなくて済む状態にするのが、
  最も確実なストレージ管理。
- **`URLSession` は必ず `.ephemeral`。** 既定設定のままだと
  `~/Library/Caches/<bundle-id>/Cache.db` が勝手に生える。HTTP キャッシュは
  `registry.json` の ETag で自前管理しており、二重に持つ理由が無い。
- **作ったものは同じ関数の中で片付ける。** ダウンロード・zip 展開・staging は
  `defer` で必ず削除する。成功・失敗・キャンセルのどの経路でも残さない。
  中途半端な残骸を後から掃除する機能を足すのは、作らない設計に負けている。
- **全部読まない。** 一覧に要るのは frontmatter だけなので**先頭 4 KB** しか読まない
  （`FileHandle.read(upToCount:)`）。本文は詳細を開いたときに読み、閉じたら捨てる。
  `~/.claude/projects` は 129 MB、`logs_*.sqlite` は 44 MB ある — 素朴に走査すると UI が固まる。
- **メモリに溜めない。** 大きい取得物は `URLSession.download` でファイルへ流す
  （`Data` で全体を保持しない）。スキャン結果はキャッシュせず、
  アクティブ化のたびに読み直して捨てる（不変条件 5）。
- **`registry.json` はアトミックに書く。** 唯一の永続ファイルなので、
  書き込み中のクラッシュで壊れると全リソースの出所情報が飛ぶ
  （`Data.write(to:options:.atomic)`）。

同じ規律をリポジトリにも適用する。**スクリプト・ドキュメント・設定ファイルも、
役割が重なるなら増やさず既存に足す。** 使われなくなったものは消す。

## 設計上のパターン

- **外部依存は `Environment`（構造体 + クロージャ）で注入する。** protocol を切らない
  （DESIGN 3.6 — 実装が 1 つしか無いものに interface を作らない）。
  テストは `Environment.test(home:)` で偽のホームを指し、**実ユーザーの `~/.claude` に
  一切到達しない**。
- **エージェント抽象に protocol を切らない。** `enum Agent` と `switch` で足りる。
- OS を触る処理は薄く端に寄せ、**判定そのものは純粋関数**にしてテストする
  （`InstallLocationClassifier` / `PasteInput.classify` / `WriteGuard.isInside` が実例）。
- **握り潰さない。** 失敗は `AppModel.errorMessage` に出して UI に見せる。
- **SourceKit の赤線は当てにしない。** 真偽は必ず `swift build` / `swift test` で判定する
  （モジュール再コンパイル前の diagnostics は古いことが多い）。

## ローカライズ

- `Localization/{ja,en}.lproj/Localizable.strings`。`build-app.sh` が `.app` に同梱する。
- **キーは日本語文字列そのもの。** `Text("…")` / `Button("…")` などのリテラルは
  SwiftUI が `LocalizedStringKey` として自動で引く。`ja` は恒等写像、`en` を翻訳する。
- **`String` を返す計算プロパティは自動で引かれない。** `String(localized: "…")` を使う
  （`Screen.title` / `helpText` / `Filter.title` が実例）。
- 引数が 2 つ以上ある文言は、**英語側を positional**（`%1$@` / `%2$lld`）にする。
  語順が日本語と逆転するため、非 positional だと引数が入れ替わる。
- 翻訳対象でないもの（差分の本文など）は `Text(verbatim:)` にする。
- 追加したら必ず両ファイルに入れる。検査は `./Scripts/check-invariants.sh`。

## テスト方針

- **Swift Testing**（`import Testing` / `@Test` / `#expect`）。
- **純粋関数を最も厚く書く**（DESIGN 10.1）。走査範囲の検査（10.2）は設計の生命線。
- ファイルシステム操作は**偽ホーム**で実行する（10.3）。CLI 呼び出しはフェイク（10.4）。
- 実 CLI・実ネットワークを使う確認は `MANUAL=1 swift test`（`_ManualCheck.swift`）。
  通常の `swift test` では無効化されている。
- **書かないもの**（10.6）: UI のスナップショット、モックを検証するだけのテスト。

## 自動テストできないもの（実機で確認する）

- **`.app` を Finder から起動したときの CLI 解決。** GUI の `PATH` はターミナルと違う
  （DESIGN 3.7）。`swift run` では再現しない
- **メニューバーのアイコン。** `MenuBarExtra` のラベルはまるごとテンプレートとして
  描かれるため、色を出すには非テンプレート画像に差し替える必要がある（実機で確認済み）。
  ダークモードでの見え方は実機でしか分からない
- **ウィンドウを閉じた常駐状態で検知が続くか**（App Nap がタイマーを間引かないか）
- symlink を張った瞬間に、稼働中の Claude / Cursor の一覧へ反映されるか
- DMG のインストール導線、設置場所ガードの表示と移動・再起動
- 公証済みビルドの初回起動が無警告か（`spctl -a -vv <app>` が `accepted`）

## コミット規約

- **日本語・Conventional Commits**。実績: `feat(scope):` `fix:` `docs:` `test:` `ci:` `chore:`。
  例: `feat(build): .app バンドルの組み立てと署名スクリプトを追加`
- **機能単位で分割**してコミットする。各コミットは `swift build` が通る状態に保つ。
- コミット・push はユーザーが求めたときだけ行う。
- **利用者に見える変更をしたら `CHANGELOG.md` の `[Unreleased]` に 1 項目足す。**
  **英語**で書く（公開 Release の本文になる。コミットメッセージは日本語のまま）。
  節見出しは `Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security` のみ。
  **版見出しへの切り出しはリリース時に CI がやるので手で移さない。**
- 仕様やテスト件数が変わったら `DESIGN.md` / `README.md` / `README.ja.md` も同時に更新する。

## CI / リリース

- **PR ゲート**: `main` 向け PR で `.github/workflows/ci.yml` が「完了の定義」を実行する。
- **リリース**: `main` から `release/Ver_X.Y.Z` を切って push → `release.yml` が
  テスト → 署名ビルド → `.app` 公証 → DMG → DMG 署名・公証 → Gatekeeper 検証 →
  **公開リポジトリへ Release 作成** → ソースへ同じタグを付与 → `main` へ CHANGELOG 反映。
- **配布は `den0206/manage-arms-releases`（公開）、ソースはこのリポジトリ（Private）**
  （DESIGN 13.8）。利用者向けの README・CHANGELOG・デモ・Issue テンプレートは配布側にあり、
  Release の公開を受けて配布側の `sync-release-docs.yml` が最新版表示を追従させる。
  **こちらの README は開発者向け。** 利用者向けの文言を足すなら配布側を直す。
- **署名・公証・公開は必須。** シークレット（署名 4 + 公証 3 + `RELEASES_TOKEN`）が
  1 つでも欠けていれば checkout より前に落ちる。
  未署名の DMG は出回ると回収できないので作らせない。手順は `docs/signing.md`。
- **公開済みリリースは不変。** 同じタグが既にあれば上書きせず `Ver_X.Y.Z+N` に採番する。
  タグの権威は publish 先の公開リポジトリ（ソース側のタグは記録用の写し）。
- サードパーティ Action は使わない（許可は公式 `actions/checkout` のみ）。

## 過剰実装のレビュー

実装が一段落したら `/ponytail:ponytail-review` を回す（差分を過剰実装の観点だけで見て、
削除・stdlib 置換の候補を出す）。**採用しない指摘**: 上記の不変条件・入力検証・
エラー処理・アクセシビリティを削るもの。リポジトリ全体を見直すときは `/ponytail:ponytail-audit`。
