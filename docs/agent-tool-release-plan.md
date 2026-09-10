# Agent Tool — 段階的リリース計画

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> リリース条件の詳細は [product-requirements.md](product-requirements.md) を参照。

---

## 概要

```
Phase 0: リネーム・リポジトリ整理
    ↓
Phase 1: プロトタイプ（社内確認）
    ↓
Phase 2: β版（GitHub Releases VSIX）
    ↓
Phase 3: 正式リリース（Cursor Marketplace）
    ↓
Phase 4: Mac App 削除・リポジトリ完全移行
```

---

## Phase 0 — リネーム・リポジトリ整理

**目的**: 開発を始める前にコードベースとリポジトリを Agent Tool へ統一する。

### タスク

| 作業 | 詳細 |
|---|---|
| コード内リネーム | `ManageArmsCore` → `AgentToolCore`、`ManageArmsApp` → `AgentToolApp`、型名・ファイル名すべて |
| `Package.swift` 更新 | `name: "ManageArms"` → `"AgentTool"`、ターゲット名を変更 |
| ドキュメント更新 | README / CHANGELOG / DESIGN.md / CLAUDE.md のすべての "ManageArms" 表記を "Agent Tool" に統一 |
| リポジトリ名変更 | `manage-arms` → `agent-tool`（GitHub の Settings > Rename） |
| npm パッケージ名設定 | `package.json` に `"name": "agent-tool"`, `"publisher": "agent-tool"` |
| ブランチ戦略確認 | `main` を継続。CI / release workflow を更新 |

### 完了条件

- `swift build && swift test` がすべてパスする
- `./Scripts/check-invariants.sh` がパスする
- コード・ドキュメントに "ManageArms" の表記が残っていない

---

## Phase 1 — プロトタイプ（社内確認）

**目的**: AgentToolCore CLI エントリポイントと TS 拡張の基本疎通を確認する。

### 実装スコープ

| 機能 | 詳細 |
|---|---|
| `AgentToolCoreCLI` ターゲット追加 | `Package.swift` に `.executableTarget` を追加 |
| `version` コマンド | `protocolVersion: "1"` を返す |
| `scan-path` コマンド | claude / cursor / codex / gemini を検知してバージョンを返す |
| `inventory` コマンド | 偽ホームで一覧を返す |
| TS 拡張の骨格 | `package.json`、Activity Bar、Tree View（ハードコードデータで表示） |
| TS → CLI 呼び出し | `child_process.spawn` + JSON stdin/stdout の疎通確認 |

### 完了条件

- CLI の 3 コマンドが動作する
- Cursor の Activity Bar に Tree View が表示される
- PATH 検知結果が Environment セクションに表示される

---

## Phase 2 — β版（GitHub Releases VSIX）

**目的**: 全対象機能を実装し、GitHub Releases で VSIX を配布する。

### 実装スコープ

| 機能 | CLI コマンド |
|---|---|
| ツール追加 | `add` |
| ツール削除 + ロールバック | `remove`, `rollback` |
| 有効化/無効化 | `toggle` |
| 更新プレビュー + 適用 | `update-preview`, `update-apply` |
| MCP サーバー追加・削除 | `mcp-add`, `mcp-remove` |
| MCP プロセス状態 | `mcp-status`（3 秒ポーリング） |
| 初回移行 | `migrate` |
| プロセス間ロック | `registry.lock` の `flock()` |
| 確認ダイアログ | 削除・上書き・CLI 設定変更 |
| WriteGuard 全不変条件 | `assertValidName`, `assertMutable`, `assertSafeCreation` |
| 未信頼ワークスペース制御 | 書き込み禁止バナー |
| Remote 環境制御 | 全操作禁止バナー |
| ファイル監視 | `createFileSystemWatcher` で Tree View を自動更新 |
| Universal Binary 同梱 | `lipo` で arm64 + x86_64 を結合して VSIX に同梱 |

### VSIX ビルド手順

```bash
# AgentToolCore CLI をビルド
swift build -c release --arch arm64
swift build -c release --arch x86_64
lipo -create -output .build/agent-tool-core \
  .build/arm64-apple-macosx/release/AgentToolCoreCLI \
  .build/x86_64-apple-macosx/release/AgentToolCoreCLI

# VSIX をパッケージ
npm run package   # vsce package
```

### 完了条件

- [product-requirements.md](product-requirements.md) の「β版」チェックリストをすべて満たす
- Cursor Stable での E2E テストがパスする
- GitHub Releases に VSIX が公開されている

---

## Phase 3 — 正式リリース（Cursor Marketplace）

**目的**: β版を 1 か月以上安定稼働させ、Cursor Marketplace に公開する。

### 追加作業

| 作業 | 詳細 |
|---|---|
| Marketplace 登録 | `vsce publish` で `agent-tool.agent-tool` を公開 |
| `publisher` 検証 | Cursor / VS Code Marketplace でパブリッシャー ID を取得 |
| バイナリ署名 | `codesign` で CLI バイナリに Developer ID を付与 |
| アイコン・ストアページ | 128×128 アイコン、説明文、スクリーンショット |
| Open VSX 登録 | `ovsx publish`（VS Code 対応フェーズの準備） |

### 完了条件

- β版を 1 か月以上重大障害ゼロで稼働
- [product-requirements.md](product-requirements.md) の「正式リリース」チェックリストをすべて満たす
- Cursor Marketplace でインストール可能

---

## Phase 4 — Mac App 削除・完全移行

**目的**: ManageArms Mac App のコードとリポジトリを削除し、Agent Tool に一本化する。

### 前提条件

- Phase 3 完了
- Mac App の全機能が Agent Tool で代替されている
- ユーザーへの移行案内を完了している

### 作業

| 作業 | 詳細 |
|---|---|
| `Sources/ManageArms/` 削除 | SwiftUI アプリターゲットを削除 |
| `Scripts/build-app.sh` 削除 | macOS .app ビルドスクリプトを削除 |
| `Scripts/release-changelog.sh` 更新 | VSIX リリース向けに書き直す |
| `.github/workflows/release.yml` 更新 | `.app` / DMG のビルドを VSIX ビルドに置き換える |
| `docs/signing.md` アーカイブ / 削除 | CLI バイナリ署名手順に書き直す |
| 配布リポジトリの更新 | `den0206/manage-arms-releases` を `den0206/agent-tool-releases` に移行または廃止 |
| リリースノート | ManageArms の最終バージョンに「Agent Tool へ移行しました」の案内を追加 |

### 完了条件

- `swift build` が AgentToolCore CLI のみビルドする
- `ManageArms` 関連のコード・スクリプト・ドキュメントが存在しない
- 旧 `manage-arms` リポジトリが `agent-tool` にリダイレクトまたはアーカイブされている

---

## バージョニング

| フェーズ | バージョン例 | 配布 |
|---|---|---|
| Phase 1 | `0.1.0-alpha.1` | 社内のみ |
| Phase 2 | `0.2.0-beta.1` 〜 | GitHub Releases |
| Phase 3 | `1.0.0` | Cursor Marketplace |
| Phase 4 | `1.x.0` | Cursor Marketplace のみ |

セマンティックバージョニング: `MAJOR.MINOR.PATCH`
- `MAJOR`: 破壊的変更（`protocolVersion` インクリメントを伴う）
- `MINOR`: 機能追加
- `PATCH`: バグ修正

---

## Mac App 並走期間のルール

Phase 2 β期間中は ManageArms Mac App と Agent Tool が同時にインストールされる可能性がある。

| ルール | 詳細 |
|---|---|
| 書き込みは Agent Tool のみ | Mac App は読み取り専用（移行後の registry.json を読む） |
| 旧 registry.json を削除しない | Mac App が参照できるよう残す |
| ロックファイルは Agent Tool が管理 | Mac App の `NSLock` と競合しない（プロセスが違うため） |
| ユーザーへの案内 | インストール時に「ManageArms は読み取り専用になります」と通知 |
