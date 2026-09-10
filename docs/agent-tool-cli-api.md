# AgentToolCore CLI — API 仕様

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> プロダクト要件は [product-requirements.md](product-requirements.md) を参照。

## 呼び出し規約

```
agent-tool-core <command>
```

- **入力**: JSON を stdin に渡す（引数なし。シェルエスケープを避けるため）
- **出力**: JSON を stdout に書く
- **終了コード**: 成功 `0`、失敗 `1`（出力 JSON 内に詳細を持つ）
- TypeScript 拡張は `protocolVersion` を起動直後に確認し、不一致なら操作を停止する

`version` 以外の入力は共通して `storagePath` を持つ。TS 拡張が
`context.globalStorageUri.fsPath` を絶対パスで渡し、CLI はこれを `Environment.appSupport` として使う。
`projectPath` が必要なコマンドも絶対パスで渡す。

CLI は1コマンドごとに終了する。キャッシュと削除 Undo 情報は TypeScript 拡張のメモリに置く。

## 共通レスポンス形式

### 成功

```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": { }
}
```

### エラー

```json
{
  "ok": false,
  "protocolVersion": "1",
  "error": {
    "code": "WRITE_GUARD_DENIED",
    "message": "..."
  }
}
```

## エラーコード一覧

| コード | 意味 |
|---|---|
| `PROTOCOL_MISMATCH` | CLI と拡張の `protocolVersion` が一致しない |
| `WRITE_GUARD_DENIED` | WriteGuard がパス・名前を拒否した |
| `INVALID_NAME` | ツール名に `../` など不正な要素が含まれる |
| `NOT_IN_REGISTRY` | Agent Tool の管理対象ではない |
| `SYMLINK_OUTSIDE_STORE` | Agent Tool 管理外を指す symlink である |
| `LOCK_TIMEOUT` | 排他ロックの取得が 10 秒以内に完了しなかった |
| `NOT_FOUND` | 指定したツールが見つからない |
| `ALREADY_EXISTS` | 同名ツールが既にインストール済み |
| `FETCH_FAILED` | ネットワーク取得失敗（HTTP ステータスとメッセージを含む） |
| `REMOTE_ENV` | Remote 環境では操作不可 |
| `UNTRUSTED_WORKSPACE` | 未信頼ワークスペースでは書き込み不可 |
| `ROLLBACK_FAILED` | ロールバックに失敗した（ゴミ箱の内容は保持） |
| `SCHEMA_UNSUPPORTED` | registry のスキーマが CLI より新しい |
| `MIGRATION_CONFLICT` | 移行先に既存データがあり上書きできない |
| `OUTPUT_TOO_LARGE` | 応答が2 MBの上限を超えた |
| `LEGACY_APP_RUNNING` | ManageArms が実行中のため破壊的操作を拒否した |
| `OPERATION_FAILED` | WriteGuard 以外の理由で操作が失敗した |

---

## コマンド一覧

### `version` — プロトコルバージョン確認

TS 拡張の起動直後に必ず呼ぶ。バージョン不一致なら以降の操作をすべて停止する。

**入力**: なし（stdin は空で可）

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "cliVersion": "1.0.0",
    "protocolVersion": "1"
  }
}
```

---

### `scan-path` — AI エージェント CLI の検知

ログインシェル（`$SHELL -l -c 'echo $PATH'`）で PATH を解決し、
対象 CLI（claude / cursor / codex / gemini）の有無とバージョンを返す。
既存の `Detector.detectAll` と `ShellPath.resolved` を使用する。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri"
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "resolvedPath": "/usr/local/bin:/opt/homebrew/bin:...",
    "agents": [
      {
        "id": "claude",
        "displayName": "Claude Code",
        "found": true,
        "path": "/usr/local/bin/claude",
        "version": "1.2.3"
      },
      {
        "id": "cursor",
        "displayName": "Cursor",
        "found": true,
        "path": "/usr/local/bin/cursor",
        "version": "0.45.0"
      },
      {
        "id": "codex",
        "displayName": "Codex",
        "found": false,
        "path": null,
        "version": null
      },
      {
        "id": "gemini",
        "displayName": "Gemini CLI",
        "found": false,
        "path": null,
        "version": null
      }
    ]
  }
}
```

---

### `inventory` — ツール一覧取得

ユーザー全体と指定プロジェクトのツールを一括返却する。
既存の `Inventory.load` を使用する。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "projectPath": "/path/to/project"
}
```

- `projectPath`: 現在のワークスペースフォルダの絶対パス。`null` を渡すとユーザー全体のみ返す

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "items": [
      {
        "id": "opaque-for-display",
        "name": "my-skill",
        "kind": "skill",
        "scope": "user",
        "agent": "claude",
        "enabled": true,
        "sourcePath": "/Users/yuuki/.claude/commands/my-skill.md",
        "repoUrl": "https://github.com/example/my-skill",
        "sha": "abc123",
        "hasUpdate": false,
        "lastUsed": "2026-09-01T12:00:00Z"
      }
    ]
  }
}
```

**フィールド定義**:

| フィールド | 型 | 説明 |
|---|---|---|
| `id` | string | Tree View 内の識別用。操作対象の復元には使わない |
| `kind` | `"skill"` \| `"subagent"` \| `"mcp"` \| `"plugin"` | ツール種別 |
| `scope` | `"user"` \| `"project"` | ユーザー全体か PJ ローカルか |
| `agent` | `"claude"` \| `"cursor"` \| `"codex"` \| `"gemini"` | 対象エージェント |
| `enabled` | boolean | 有効状態（symlink の有無で判定） |
| `repoUrl` | string \| null | 取得元リポジトリ URL（registry.json 由来） |
| `sha` | string \| null | インストール時の Git SHA |
| `hasUpdate` | boolean | registry に記録された直近の更新確認結果 |
| `lastUsed` | ISO 8601 \| null | 最終使用日時（usage ログ由来） |

操作コマンドは区切り文字列の ID ではなく、次の `selector` をそのまま渡す。CLI は毎回
インベントリを再走査し、`sourcePath` を含む全フィールドが一致する1件だけを操作する。

```json
{
  "name": "my-skill",
  "kind": "skill",
  "scope": "user",
  "agent": "claude",
  "sourcePath": "/Users/yuuki/.claude/skills/my-skill"
}
```

---

### `toggle` — 有効化 / 無効化

`Inventory.toggle` を経由して `SkillManager` / `SubagentManager` の enable / disable を呼ぶ。
WriteGuard を通過する。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "selector": {
    "name": "my-skill", "kind": "skill", "scope": "user",
    "agent": "claude", "sourcePath": "/Users/yuuki/.claude/skills/my-skill"
  }
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "enabled": false
  }
}
```

---

### `remove` — ツール削除

Skill / Subagent は `Inventory.remove`、Plugin は `Inventory.removeExisting` を経由する。
ファイル実体は WriteGuard を通して OS ゴミ箱へ移し、Plugin は対象 Agent の CLI に委譲する。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "selector": {
    "name": "my-skill", "kind": "skill", "scope": "user",
    "agent": "claude", "sourcePath": "/Users/yuuki/.claude/skills/my-skill"
  }
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "undo": {
      "originalPath": "/Users/yuuki/.agents/skills/my-skill",
      "trashedPath": "/Users/yuuki/.Trash/my-skill",
      "registryEntry": {
        "name": "my-skill",
        "kind": "skill",
        "repo": "https://github.com/example/my-skill",
        "branch": "main",
        "subdir": null,
        "sha": "abc123def456",
        "pinned": false,
        "disabled": false
      }
    }
  }
}
```

- TS 拡張は `undo` を30秒だけメモリ保持する。ディスクへ保存しない

---

### `rollback` — 削除の取り消し

`remove` が返した `undo` をそのまま使って操作を取り消す。
CLI はパスと registry entry を再検証し、ゴミ箱から実体を戻して symlink と registry を復元する。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "undo": {
    "originalPath": "/Users/yuuki/.agents/skills/my-skill",
    "trashedPath": "/Users/yuuki/.Trash/my-skill",
    "registryEntry": {
      "name": "my-skill",
      "kind": "skill",
      "repo": "https://github.com/example/my-skill",
      "branch": "main",
      "subdir": null,
      "sha": "abc123def456",
      "pinned": false,
      "disabled": false
    }
  }
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "restoredPath": "/Users/yuuki/.agents/skills/my-skill"
  }
}
```

---

### `add` — Skill 追加

URL（GitHub リポジトリまたはファイル直リンク）から Skill を取得してインストールする。
`Fetcher` → `Installer` → WriteGuard のパスを通る。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "url": "https://github.com/example/my-skill",
  "scope": "user",
  "projectPath": "/path/to/project",
  "agent": "claude",
  "kind": null
}
```

- `kind`: 候補の判別結果を返すために残すが、初版でインストールできるのは `skill` だけ
- `scope`: `"project"` の場合は `projectPath` が必須

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "name": "my-skill",
    "kind": "skill",
    "installedPath": "/Users/yuuki/.claude/commands/my-skill.md",
    "sha": "def456"
  }
}
```

---

### `update-preview` — 更新差分プレビュー

`Updater.preview` を呼び、変更前後の内容を返す。
TypeScript 拡張は内容をメモリ上の `TextDocumentContentProvider` に渡して Diff Editor で開き、
Editor を閉じたら破棄する。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "selector": {
    "name": "my-skill", "kind": "skill", "scope": "user",
    "agent": "claude", "sourcePath": "/Users/yuuki/.claude/skills/my-skill"
  }
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "currentSha": "abc123",
    "latestSha": "def456",
    "files": [
      {
        "path": "my-skill.md",
        "before": "current file contents",
        "after": "updated file contents"
      }
    ]
  }
}
```

---

### `update-apply` — 更新適用

`Updater.apply` を呼ぶ。WriteGuard を通し、適用中に失敗した場合は同じプロセス内で元へ戻す。
適用完了後の Undo は提供しない。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "selector": {
    "name": "my-skill", "kind": "skill", "scope": "user",
    "agent": "claude", "sourcePath": "/Users/yuuki/.claude/skills/my-skill"
  }
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "appliedSha": "def456"
  }
}
```

---

### `mcp-add` — MCP サーバー追加

`MCPManager.add` を呼ぶ。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "agent": "claude",
  "scope": "user",
  "projectPath": "/path/to/project",
  "server": {
    "name": "my-server",
    "command": "node",
    "args": ["/path/to/server.js"],
    "env": {
      "API_KEY": "..."
    }
  }
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "name": "my-server",
    "agent": "claude"
  }
}
```

---

### `mcp-remove` — MCP サーバー削除

`MCPManager.remove` / `MCPManager.removeProject` を呼ぶ。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "agent": "claude",
  "name": "my-server",
  "scope": "user",
  "projectPath": "/path/to/project"
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "removed": "my-server"
  }
}
```

---

### `mcp-status` — MCP プロセス状態取得

`ProcessScanner` を呼んで起動中の MCP サーバー PID を返す。
View 表示中に 3 秒ポーリングで呼ぶ。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "projectPath": "/path/to/project"
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "servers": [
      {
        "name": "my-server",
        "running": true,
        "pid": 12345
      },
      {
        "name": "other-server",
        "running": false,
        "pid": null
      }
    ]
  }
}
```

---

### `migrate` — ManageArms からの移行

初回起動時に `~/Library/Application Support/ManageArms/registry.json` を検知したら呼ぶ。
registry と管理対象の Subagent・無効化中実体を `globalStorageUri` へコピーする。
移行先が存在する場合は上書きせず `MIGRATION_CONFLICT` を返す。

**入力**:
```json
{
  "storagePath": "/path/to/globalStorageUri",
  "sourcePath": "/Users/yuuki/Library/Application Support/ManageArms"
}
```

**出力**:
```json
{
  "ok": true,
  "protocolVersion": "1",
  "data": {
    "migratedEntries": 12,
    "skipped": 0,
    "targetPath": "/path/to/globalStorageUri/registry.json"
  }
}
```

---

## 型定義まとめ（TypeScript 拡張向け）

```typescript
type AgentId = "claude" | "cursor" | "codex" | "gemini";
type KindId  = "skill" | "subagent" | "mcp" | "plugin";
type ScopeId = "user" | "project";

interface CliResponse<T> {
  ok: boolean;
  protocolVersion: "1";
  data?: T;
  error?: { code: string; message: string };
}

interface InventoryItem {
  id: string;           // Tree View 内の表示識別用
  name: string;
  kind: KindId;
  scope: ScopeId;
  agent: AgentId;
  enabled: boolean;
  sourcePath: string;
  repoUrl: string | null;
  sha: string | null;
  hasUpdate: boolean;
  lastUsed: string | null;  // ISO 8601
}

interface ResourceSelector {
  name: string;
  kind: KindId;
  scope: ScopeId;
  agent: AgentId;
  sourcePath: string;
}
```

---

## 実装メモ

- CLI エントリポイントは `Package.swift` に新規 `.executableTarget(name: "AgentToolCoreCLI")` として追加する
- Phase 0 で改名した `AgentToolCore` を再利用し、CLI 用 `Environment` と DTO 変換だけを追加する
- 各サブコマンドは `switch commandName` で振り分け、stdin を `JSONDecoder` でデコードして対応する関数を呼ぶ
- 180秒キャッシュ、削除 Undo、Diff Editor の本文は TypeScript 拡張のメモリだけに保持する
- `protocolVersion` は `1` から始め、破壊的変更が入るたびに整数インクリメントする
