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

`scanPath()` の結果を一覧の上に折りたたみで表示する（View 表示時に 1 回、手動更新で引き直す）。

```
▾ 🌐 Environment
    ● claude     1.2.3    /usr/local/bin/claude
    ● cursor     0.45.0   /Applications/Cursor.app/...
    ○ codex      —        not found  [インストール方法を見る ↗]
    ○ gemini     —        not found  [インストール方法を見る ↗]
```

- 折りたたみの見出しに「検出済み / 全体」を出す。開くと未検出の CLI も並ぶ
- 1 つも見つからないときは一覧の上に警告バナーを出す（§8.4）
- 手動更新ボタンで再スキャンできる

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
| ピン留め | `✓ my-skill · 📌 固定中` — 更新を追わない。`•••` から切り替える |

カードを開くと、説明・使い方・場所・取得元を出す。

**最終使用は出さない。** 使用実績は `~/.claude/projects`（129 MB）や `logs_*.sqlite` を読まないと
分からず、一覧表示の応答目標を壊す。走査ホワイトリストにも入れない（`ide/source.ts`）。

説明・使い方・場所・取得元は、カードそのものをクリックするとカードの直下に開き、
もう一度クリックすると閉じる（Enter / Space も同じ）。`•••` は管理操作だけを出す。

### 3.2 MCP Server アイテム

```
● running-server   [●]     ← クリックで pid/コマンドをポップアップ
○ stopped-server
```

MCP Server の起動状態は View 表示中のみ 3 秒ポーリング（`mcp-status` コマンド）で更新する。
View を閉じるとポーリングを停止する。

### 3.3 他のプロジェクト

User Global の一覧の下にドロップダウンを置き、現在のワークスペース以外のプロジェクトを 1 件選んで
その project スコープのツールを見せる。

```
▾ Other projects
    [ プロジェクトを選択 ▾ ]
    /path/to/other-project
    ✓ their-skill              ← クリックで説明・場所を開く（再クリックで閉じる）
```

- 候補は `~/.claude.json` の `projects` キーのうち、実在してツールを持つプロジェクトだけ（`knownProjects`）。
  ホームは走査しない（不変条件 3）。
- ツールの有無は直下の `.claude/skills`・`.claude/agents`・`.mcp.json` と、
  `~/.claude.json` の `projects[path].mcpServers` だけで決める。候補全件に深さ 3 の走査は掛けない。
- 走査するのは選ばれた 1 件だけ（`inventory` の `user: false`）。Webview から届くパスは信頼せず、候補に載っているものだけ受け付ける。
- Plugin は `projectPath` が選んだパスと一致するものだけ。他プロジェクト分は載せない。
- 走査失敗は空一覧にせず、理由を出す（メイン一覧の `issues` と同じ）。
- 表示は読み取り専用。管理できるのは開いているワークスペースの project スコープだけで、
  他プロジェクトの実体には `projectPath` を渡さない（`isManageable` が false になる）。
- MCP の起動状態は出さない。ポーリングは user スコープの登録だけを見ている。
- 結果は Webview 側にだけ置き、View を閉じたら捨てる。

---

## 4. 操作フロー

### 4.1 ツール追加

**方法 A: コマンドパレットから URL 貼り付け**

```
1. Cmd+Shift+P → "Agent Tool: Add Skill"
2. Quick Input が開く
   "GitHub URL を貼り付けてください"
   > https://github.com/example/my-skill
3. スコープ選択 Quick Pick（ワークスペースが開いていないときは出さず user に入れる）
   ● User Global       すべてのプロジェクトで使えます
   ○ Current Project   /path/to/project
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
| `agent-tool.addSkill` | GitHubからSkillを追加 | URL を入力してインストール（スコープを選ぶ） |
| `agent-tool.addMcp` | MCPサーバーを追加 | JSON・HTTP URL・起動コマンドから追加 |
| `agent-tool.refreshInventory` | ツールを再読み込み | キャッシュを破棄して再走査 |
| `agent-tool.checkUpdates` | 更新を確認 | 取得元の最新 SHA を引き、更新バッジを立てる |
| `agent-tool.toggleTool` | ツールの有効・無効を切り替え | user スコープのみ |
| `agent-tool.togglePin` | 更新の固定を切り替え | 固定中は更新を追わない |
| `agent-tool.removeTool` | ツールを削除 | 確認あり |
| `agent-tool.previewUpdate` | 更新をプレビュー | Diff Editor を開く |
| `agent-tool.applyUpdate` | 更新を適用 | 確認あり |
| `agent-tool.openToolActions` | ツールを管理 | カードの `•••` から呼ぶ操作一覧 |

CLI の再検出は手動更新（`refreshInventory`）に含める。MCP のプロセス情報は表示中の
3 秒ポーリングで出すので、専用コマンドは持たない。

---

## 7. Status Bar

Cursor の Status Bar 右端に更新件数バッジを表示する。

```
[⬆ 3 updates]
```

- クリックで Dashboard にフォーカスする（`agent-tool.inventory.focus`）
- 更新なしのときは非表示
- `inventory` の `hasUpdate: true` な件数をカウントする。件数が立つのは
  `checkUpdates` を実行したあと（`registry.repos` に `latestSha` が入ったとき）

---

## 8. エラー表示

### 8.1 Remote 環境（SSH / Dev Container / Codespaces）

一覧の上にバナーを表示する。書き込み操作は実行時にも拒否する:

```
╔═════════════════════════════════════════════╗
║ ⚠ Agent Tool はローカル環境でのみ動作します  ║
║ Remote 接続中は操作できません。              ║
╚═════════════════════════════════════════════╝
```

### 8.2 未信頼ワークスペース

一覧の上にバナーを表示する。書き込み操作は実行時にも拒否する:

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

### 8.4 CLI 未検出（`scanPath()` が 1 つも見つけない）

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

---

## 10. ブラウザ拡張

### 10.1 画面構成

画面は 2 つだけとする。`showDirectoryPicker()` はポップアップから呼ぶとポップアップが閉じて
処理が中断するため、許可を伴う操作はすべて専用タブで行う（設計決定 D-17）。

| 画面 | 役割 |
|---|---|
| 検知バナー | 対応サイトの閲覧中に content script が Shadow DOM で挿す帯 |
| 専用タブ | 導入先の選択、ディレクトリ許可、URL 入力、収集一覧、設定 |

ツールバーのアイコンは専用タブを開く。バナーの ON / OFF は設定で切り替える。

### 10.2 検知バナー

```
╔═══════════════════════════════════════════════════╗
║ 🧩 スキル「pdf」を見つけました                      ║
║    example/my-skills                              ║
║                        [導入する]  [今はしない]     ║
╚═══════════════════════════════════════════════════╝
```

- 出すのは github.com / skills.sh / agentsdirectory.dev だけ。
- パス名で候補にしたあと `raw.githubusercontent.com` の実在確認が通ってから出す。
  確認の往復中にページを離れていたら出さない。
- 許可済みエージェントのディレクトリに同名があれば出さない。未許可なら収集一覧で判定する。
- 「今はしない」はこのセッション中だけ記憶する。永続化しない。
- Shadow DOM に閉じ込め、ページの CSS を継承しない。

### 10.3 導入フロー

```
1. バナーの [導入する]、または専用タブに URL を貼る
2. 専用タブが開く
   ┌─────────────────────────────────────────────┐
   │ スキル「pdf」 — example/my-skills           │
   │ 説明文（frontmatter の description）         │
   │                                             │
   │ 導入先                                       │
   │   ● Claude Code      ~/.claude/skills       │
   │   ○ Cursor           （許可が必要です）      │
   │   ○ Codex            （許可が必要です）      │
   │                             [導入する]       │
   └─────────────────────────────────────────────┘
3. 未許可の導入先を選んだら、ピッカーを開く前に OS 別の手順を出す
   「macOS では Cmd+Shift+. を押すと隠しフォルダが表示されます」
4. 導入先ルートそのものを選ぶ → 選択したディレクトリ名を確認 → IndexedDB に保持
5. 取得・展開（進捗表示）
6. 同名があれば上書き確認
7. 完了 → 収集一覧に追加
```

- その種別に対応するエージェントは常に全て並べ、許可済みかどうかを注記で示す。
  選択肢が毎回同じで、初回に何ができるかが分かる。
- Gemini CLI は MCP だけを対象にするため現れない。Codex は Skill だけに現れる。
- 拡張を入れた直後に何も開かない。最初に導入を押した時点で許可の意味を説明する。

### 10.4 削除

収集一覧から、自分が入れ、導入時の実体ツリー SHA-256 と一致するものだけ削除できる。
手動変更されたものは削除せず、変更されたためブラウザ拡張では削除できないと表示する。
確認ダイアログは IDE 拡張の 5.1 と同じく、取り消せないことを示す。

### 10.5 エラー表示

| 状況 | 表示 |
|---|---|
| ディレクトリ許可が失効した | 「もう一度許可してください」と再許可ボタン |
| 選ばれた場所が想定と違う | 絶対パスは得られないため、選択したディレクトリ名を示し、導入先ルートを選び直すよう求める |
| 取得が上限を超えた | 上限値と実測値を示して中止する |
| 実在確認が通らない | バナーを出さない。利用者には何も見せない |
| Plugin のページを見ている | 何も出さない（ブラウザ拡張は Plugin を扱わない） |

パス・コマンド・差分は IDE 拡張と同じく verbatim で表示する。
