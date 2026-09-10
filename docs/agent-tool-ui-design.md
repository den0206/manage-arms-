# Agent Tool — UI 情報設計

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> モジュール API 仕様は [agent-tool-cli-api.md](agent-tool-cli-api.md) を参照。

---

## 1. Activity Bar パネル構成

Cursor の Activity Bar に **Agent Tool** アイコンを追加する。クリックで以下の Tree View を開く。

```
AGENT TOOL                                    [＋ Add] [⟳ Refresh]
─────────────────────────────────────────────────────────────────
▾ 🌐 Environment
    ● claude     1.2.3    /usr/local/bin/claude
    ● cursor     0.45.0   /usr/local/bin/cursor
    ○ codex      —        not found
    ○ gemini     —        not found

▾ 📁 Current Project  (/path/to/project)
  ▾ Claude Code
    ▾ Skills
        ✓ my-skill        [⬆] [⊘] [🗑]
    ▾ Subagents
        ✓ my-agent
    ▾ MCP Servers
        ● running-server  [●]
    ▾ Plugins
        (none)

▾ 👤 User Global
  ▾ Claude Code
    ▾ Skills
        ✓ global-skill  ⬆2  [⬆] [⊘] [🗑]
    ▾ Subagents
        (none)
    ▾ MCP Servers
        ● my-mcp      [●]
    ▾ Plugins
        ✓ ponytail
  ▸ Cursor
  ▸ Codex
  ▸ Gemini CLI
─────────────────────────────────────────────────────────────────
```

**アイコン凡例:**

| 記号 | 意味 |
|---|---|
| `●` / `○` | CLI: found / not found。MCP Server: running / stopped |
| `✓` / `✗` | Tool: enabled / disabled |
| `⬆` | 更新あり（数字付きは件数） |
| `[⬆]` | 更新ボタン（インライン） |
| `[⊘]` | 有効化/無効化トグルボタン |
| `[🗑]` | 削除ボタン |
| `[●]` | MCP ステータス表示（クリックでプロセス情報） |

---

## 2. Environment セクション

`scanPath()` の結果を表示する（拡張の `activate` 時に 1 回実行）。

```
▾ 🌐 Environment
    ● claude     1.2.3    /usr/local/bin/claude
    ● cursor     0.45.0   /Applications/Cursor.app/...
    ○ codex      —        not found  [インストール方法を見る ↗]
    ○ gemini     —        not found  [インストール方法を見る ↗]
```

- `not found` の CLI にはドキュメントリンクを表示する
- 手動更新ボタンで再スキャンできる
- PATH の解決元（`$SHELL -l -c 'echo $PATH'` の結果）をツールチップで確認できる

---

## 3. Tree View アイテム詳細

### 3.1 Skill / Subagent アイテム

```
[アイコン] [名前]  [更新バッジ]  [インラインボタン]
```

| 状態 | 表示例 |
|---|---|
| 有効・更新なし | `✓ my-skill                [⊘] [🗑]` |
| 有効・更新あり | `✓ my-skill  ⬆             [⬆] [⊘] [🗑]` |
| 無効 | `✗ my-skill                [⊘] [🗑]` |
| ピン留め | `✓ my-skill  📌            [⊘] [🗑]` |

ホバー時ツールチップ:
```
my-skill
ソース: https://github.com/example/my-skill
SHA: abc123
最終使用: 2026-09-09
```

### 3.2 MCP Server アイテム

```
● running-server   [●]     ← クリックで pid/コマンドをポップアップ
○ stopped-server
```

MCP Server の起動状態は View 表示中のみ 3 秒ポーリング（`mcp-status` コマンド）で更新する。
View を閉じるとポーリングを停止する。

---

## 4. 操作フロー

### 4.1 ツール追加

**方法 A: コマンドパレットから URL 貼り付け**

```
1. Cmd+Shift+P → "Agent Tool: Add Skill"
2. Quick Input が開く
   "GitHub URL を貼り付けてください"
   > https://github.com/example/my-skill
3. スコープ選択 Quick Pick
   ● User Global  (~/.claude/)
   ○ Current Project  (.claude/)
4. 取得・インストール中（プログレスバー）
5. 完了 → Tree View が自動更新
```

**方法 B: クリップボード自動検出**

クリップボードに GitHub URL がある状態でパネルを開くと、
Tree View 上部に候補カードを表示する:

```
╔═════════════════════════════════════════╗
║ クリップボードに URL があります           ║
║ https://github.com/example/my-skill     ║
║ [追加する]  [閉じる]                     ║
╚═════════════════════════════════════════╝
```

### 4.2 ツール削除

```
1. アイテムの [🗑] をクリック
2. 確認ダイアログ（→ セクション 5.1）
3. [削除] 実行 → remove()
4. 通知バー: "my-skill を削除しました"
   → Undo は提供しない（設計決定 D-5）。取り消せないことは 5.1 の確認ダイアログで示す
```

### 4.3 有効化 / 無効化

```
1. アイテムの [⊘] をクリック
2. 確認なし（破壊的操作ではない）
3. toggle コマンド実行
4. ✓ ↔ ✗ がリアルタイムで切り替わる
```

### 4.4 更新（差分プレビュー → 適用）

```
1. アイテムの [⬆] をクリック
2. update-preview コマンド実行
3. VS Code Diff Editor が開く
   左ペイン: 現在バージョン（abc123）
   右ペイン: 最新バージョン（def456）
4. ユーザーが差分を確認
5. エディタ上部の通知バー:
   "my-skill の更新を適用しますか？"  [適用] [キャンセル]
6. [適用] → 確認ダイアログ（→ セクション 5.2）
7. update-apply コマンド実行
8. 通知バー: "更新しました"
```

---

## 5. 確認ダイアログ仕様

すべての確認ダイアログは VS Code `window.showWarningMessage` または専用モーダルで表示する。

### 5.1 削除確認

```
┌─────────────────────────────────────────────┐
│ ⚠  my-skill を削除しますか？                  │
│                                              │
│ 対象: ~/.claude/commands/my-skill.md         │
│ エージェント: Claude Code                     │
│ スコープ: User Global                        │
│                                              │
│ この操作は取り消せません。                    │
│ 実体とリンクを完全に削除します。              │
│                                              │
│            [キャンセル]  [削除]              │
└─────────────────────────────────────────────┘
```

### 5.2 更新適用確認

```
┌─────────────────────────────────────────────┐
│ ⬆  my-skill を更新しますか？                  │
│                                              │
│ 現在: abc123  →  最新: def456                │
│ 対象: ~/.claude/commands/my-skill.md         │
│                                              │
│ ピン留めを解除して更新します。               │
│                                              │
│            [キャンセル]  [更新を適用]        │
└─────────────────────────────────────────────┘
```

### 5.3 MCP サーバー設定変更確認

```
┌─────────────────────────────────────────────┐
│ ⚠  MCP サーバー設定を変更しますか？           │
│                                              │
│ 操作: 追加                                   │
│ サーバー名: my-server                        │
│ コマンド: node /path/to/server.js            │
│ 設定ファイル: ~/.cursor/mcp.json             │
│ エージェント: Cursor                         │
│                                              │
│            [キャンセル]  [変更する]          │
└─────────────────────────────────────────────┘
```

---

## 6. コマンドパレット一覧

| コマンド ID | タイトル（日本語） | 説明 |
|---|---|---|
| `agent-tool.addTool` | Skill を追加 | URL を入力してインストール |
| `agent-tool.refreshInventory` | 一覧を更新 | キャッシュを破棄して再走査 |
| `agent-tool.rescanPath` | CLI を再検出 | `scanPath()` を再実行 |
| `agent-tool.toggleTool` | ツールを有効化/無効化 | 選択中アイテムをトグル |
| `agent-tool.removeTool` | ツールを削除 | 選択中アイテムを削除（確認あり） |
| `agent-tool.previewUpdate` | 更新をプレビュー | Diff Editor を開く |
| `agent-tool.applyUpdate` | 更新を適用 | 選択中アイテムを更新（確認あり） |
| `agent-tool.showMcpStatus` | MCP ステータスを表示 | 選択サーバーのプロセス情報 |
| `agent-tool.migrateFromManageArms` | ManageArms から移行 | 手動で移行フローを開始 |
| `agent-tool.openDocs` | ドキュメントを開く | GitHub リポジトリを開く |

---

## 7. Status Bar

Cursor の Status Bar 右端に更新件数バッジを表示する。

```
[⬆ 3 updates]
```

- クリックで Tree View にフォーカスし、更新があるアイテムまでスクロール
- 更新なしのときは非表示
- `inventory` コマンドの `hasUpdate: true` な件数をカウント

---

## 8. エラー表示

### 8.1 Remote 環境（SSH / Dev Container / Codespaces）

Tree View 全体を無効化し、上部にバナーを表示する:

```
╔═════════════════════════════════════════════╗
║ ⚠ Agent Tool はローカル環境でのみ動作します  ║
║ Remote 接続中は操作できません。              ║
╚═════════════════════════════════════════════╝
```

### 8.2 未信頼ワークスペース

書き込みボタン（追加・削除・更新・トグル）を無効化し、バナーを表示する:

```
╔══════════════════════════════════════════════╗
║ 🔒 未信頼ワークスペース — 一覧のみ表示します  ║
║ 操作するにはワークスペースを信頼してください。 ║
║ [ワークスペースを信頼する ↗]                  ║
╚══════════════════════════════════════════════╝
```

### 8.3 WriteGuard 拒否

操作失敗時は通知バー（エラー）で表示する:

| エラーコード | 表示メッセージ |
|---|---|
| `WRITE_GUARD_DENIED` | `<path> は保護対象です` |
| `INVALID_NAME` | `<name> は名前として使えません（取得元の指定を確認してください）` |
| `NOT_IN_REGISTRY` | `<name> は他のツールが管理しています` |
| `SYMLINK_OUTSIDE_STORE` | `<path> は Agent Tool が張ったリンクではありません` |
| `LOCK_TIMEOUT` | `書き込みロックを取得できませんでした（他のウィンドウが操作中の可能性があります）` |

macOS で ManageArms の起動を検知した場合は、モジュールを呼ぶ前に拡張が
`ManageArms を終了してから再実行してください` と警告して操作を中止する。

### 8.4 CLI 未検出（`scanPath()` が何も返さない）

```
╔══════════════════════════════════════════════╗
║ ⚠ AI エージェント CLI が見つかりません        ║
║ claude / cursor のいずれもインストールされて   ║
║ いないか、PATH に含まれていません。            ║
║ [セットアップガイドを見る ↗]                  ║
╚══════════════════════════════════════════════╝
```

---

## 9. ファイル監視によるリアルタイム更新

TS 拡張は `vscode.workspace.createFileSystemWatcher` と `RelativePattern` で以下を監視する。
変更を検知したら `inventory` コマンドを再実行して Tree View を更新する（キャッシュを破棄）。

| 監視パターン | 対象 |
|---|---|
| `~/.agents/skills/**` | 管理対象の共有 Skill |
| `~/.claude/skills/**` | Claude Skill |
| `~/.cursor/skills/**` | Cursor Skill |
| `~/.codex/skills/**` | Codex Skill |
| `~/.claude/agents/**` | User Global サブエージェント |
| `~/.cursor/agents/**` | Cursor サブエージェント |
| `<globalStorageUri>/disabled-skills/**` | 無効化された Skill 実体 |
| `<globalStorageUri>/disabled-agents/**` | 無効化された Subagent 実体 |
| `<workspaceFolder>/.claude/skills/**` | Current Project スキル |
| `<workspaceFolder>/.claude/agents/**` | Current Project サブエージェント |
| `<workspaceFolder>/.mcp.json` | Current Project MCP |
| `~/.cursor/mcp.json` | Cursor MCP 設定 |
| `~/.claude.json` | Claude MCP・プロジェクト設定 |
| `~/.gemini/settings.json` | Gemini MCP 設定 |

**注意:**
- `~/.claude/projects/` や `logs_*.sqlite` は監視対象に含めない（大容量・高頻度）
- ファイル監視は `globPattern` を最小限に絞り、ホワイトリスト外を監視しない
- View が非表示になったら watcher、ポーリング、キャッシュを破棄する。再表示時に全件再走査する
