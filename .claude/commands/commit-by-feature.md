---
description: 未コミット変更をレビューし、機能・役割ごとに分けて Conventional Commit する
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(npm run:*), Bash(./scripts/check-invariants.sh), Bash(./scripts/release-changelog.sh:*), Bash(./scripts/test-release-changelog.sh)
---

# 機能別に Conventional Commit でコミットする

現在の未コミット変更を**レビューしたうえで**、**機能・役割ごとに分けて**複数のコミットに分割する。

**必ずコミット前にレビューする。** レビュー不合格のまま `git commit` しない。

## いまの状態

- 変更・未追跡: !`git status -s`
- 直近のコミット: !`git log --oneline -5`

## 手順

### 1. 変更の把握

`git status -s` と `git diff`（必要なら `--cached`）で変更・未追跡ファイルを一覧し、
役割ごとに**論理的なグループ**へ分類する。

| グループ例 | 対象の目安 |
|---|---|
| `core` | `src/`の走査・追加・更新・集計・権限 |
| `extension` | `src/`・`test/` の Cursor UI・CLI 境界・テスト |
| `i18n` | `l10n/` |
| `build` | `package.json`・`scripts/`・`.vscode/` |
| `release` | `.github/workflows/`・リリーススクリプト・`CHANGELOG.md` |
| `ci` | `.github/workflows/`・`scripts/check-invariants.sh` |
| `docs` | `README.md`・`README.ja.md`・`DESIGN.md`・`CLAUDE.md`・`docs/` |

- 同じ機能の「新規ファイル」「既存ファイルの修正」「対応するテスト」は**同じグループ**に含める。
- **ローカライズは、それを使うコードと同じコミットに入れる**（`ja`/`en` は必ず両方）。
- `CHANGELOG.md` の `[Unreleased]` への追記は、その変更を入れるコミットに含める。

### 2. コミット前レビュー（必須）

グループごとに次を確認する。1 つでも引っかかったら**直してからコミットする**。

**不変条件**（`CLAUDE.md`「絶対に守る不変条件」）

- 設定ファイルの書き込みが `PermissionWriter` / `Registry` / `MCPScanner` の外に出ていないか
- 削除・移動・symlink 作成が `WriteGuard` を通る経路の外に出ていないか
- 走査対象がホワイトリスト（`Source` の列挙）から外れていないか
- `ja` / `en` のキー集合が一致しているか

**ストレージ・メモリの規律**（`CLAUDE.md`「ストレージ・メモリの規律」）

- **無駄なファイルを増やしていないか。** 管理対象実体以外の恒久ファイル・キャッシュ・ログを足していないか
- 作った一時物をTypeScriptの`finally`で確実に片付けているか
- 全部読んでいないか（frontmatter だけで足りるところで本文を読んでいないか）
- 役割の重なるスクリプト／ドキュメントを新設していないか（既存に足せないか）

**その他**

- `String` を返す計算プロパティで `String(localized:)` を忘れていないか
- 失敗を握り潰していないか（`errorMessage` に出しているか）
- 純粋関数にできる判定を OS 依存のまま書いていないか

### 3. 「完了の定義」を通す

```bash
npm run typecheck && npm test
./scripts/check-invariants.sh
./scripts/release-changelog.sh --check && ./scripts/test-release-changelog.sh
```

`package.json`が定めるNodeテスト・型検査・VSIX組み立ても実行する。

**すべて緑になるまでコミットしない。**

### 4. グループごとにコミット

```bash
git add <そのグループのファイル>
git commit
```

- **日本語・Conventional Commits**。`feat(scope):` `fix:` `docs:` `test:` `ci:` `chore:`
- 件名は 1 行で「何をしたか」。本文には**なぜそうしたか**を書く（何をしたかは diff が語る）
- **各コミット単体で `npm run typecheck && npm test` が通る状態に保つ。**
  依存する実装とテストは同じコミットに含め、分割できないものは無理に割らない
- 依存関係のある順に積む（例: Core → UI → i18n → docs）

### 5. 報告

作ったコミットを `git log --oneline` で示し、**分割の理由**と、
レビューで直した点があればそれも述べる。

## やらないこと

- **push はしない。** ユーザーが明示的に求めたときだけ。
- `CHANGELOG.md` の版見出しへの切り出し（リリース時に CI がやる）。
- 「とりあえず全部入り」の 1 コミット。逆に、ビルドが通らなくなるまでの過剰な分割。
