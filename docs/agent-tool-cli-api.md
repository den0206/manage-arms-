# Agent Tool — TypeScript モジュール API 仕様

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> プロダクト要件は [product-requirements.md](product-requirements.md) を参照。

> **移行注記（2026-09-10）**: Swift CLI サブプロセスを廃止し、VS Code 拡張内の TypeScript だけで完結する設計に変更した（設計決定 D-2）。
> 旧 CLI の JSON 仕様はこのファイル末尾の「参考」セクションに移した。

---

## 呼び出し規約

すべての操作は `src/agentTool.ts` が export する非同期関数として提供する。

- **入出力**: TypeScript の型付きオブジェクト（JSON シリアライズ不要）
- **失敗**: `AgentToolError` を throw する（`code` フィールドで種別を判定）
- **storagePath**: `context.globalStorageUri.fsPath` を渡す（OS 別パスは VS Code API が解決）
- **PROTOCOL_VERSION**: モジュールが export する定数 `"1"`。破壊的変更時にインクリメントする

---

## エラー型

```typescript
// src/agentTool.ts
export const PROTOCOL_VERSION = "1";

export type ErrorCode =
  | 'WRITE_GUARD_DENIED'    // WriteGuard がパス・名前を拒否した
  | 'INVALID_NAME'          // ツール名に ../  など不正な要素が含まれる
  | 'NOT_IN_REGISTRY'       // Agent Tool の管理対象ではない
  | 'SYMLINK_OUTSIDE_STORE' // Agent Tool 管理外を指す symlink である
  | 'LOCK_TIMEOUT'          // 排他ロックの取得が 10 秒以内に完了しなかった
  | 'NOT_FOUND'             // 指定したツールが見つからない
  | 'ALREADY_EXISTS'        // 同名ツールが既にインストール済み
  | 'FETCH_FAILED'          // ネットワーク取得失敗（HTTP ステータスを含む）
  | 'REMOTE_ENV'            // Remote 環境では操作不可
  | 'UNTRUSTED_WORKSPACE'   // 未信頼ワークスペースでは書き込み不可
  | 'SCHEMA_UNSUPPORTED'    // registry のスキーマがモジュールより新しい
  | 'MIGRATION_CONFLICT'    // 移行先に既存データがあり上書きできない
  | 'OPERATION_FAILED';     // WriteGuard 以外の理由で操作が失敗した

export class AgentToolError extends Error {
  constructor(readonly code: ErrorCode, message: string) {
    super(message);
    this.name = 'AgentToolError';
  }
}
```

**廃止**: `PROTOCOL_MISMATCH`・`ROLLBACK_FAILED`・`OUTPUT_TOO_LARGE`・`LEGACY_APP_RUNNING` は CLI 廃止により不要になった。

---

## 型定義

```typescript
// src/agentTool.ts

export type AgentId  = 'claude' | 'cursor' | 'codex' | 'gemini';
export type KindId   = 'skill' | 'subagent' | 'mcp' | 'plugin';
export type ScopeId  = 'user' | 'project';

export type Selector = {
  name: string;
  kind: KindId;
  scope: ScopeId;
  agent: AgentId;
  sourcePath?: string;
};

export type InventoryItem = {
  name: string;
  kind: KindId;
  scope: ScopeId;
  agents: AgentId[];       // 複数エージェントで共有する場合がある
  enabled: boolean;
  origin: 'managed' | 'user' | 'bundled';
  sourcePath?: string;
  repoUrl?: string;
  hasUpdate: boolean;
  summary?: string;        // frontmatter の先頭 4 KB から取得
  detail?: string;         // 詳細表示中のみ保持、閉じたら破棄
};

export type McpServerDefinition = {
  name: string;
  command: string;
  args?: string[];
  env?: Record<string, string>;
};

export type PreviewCandidate = {
  kind: KindId;
  name: string;
  installSelector?: string;
  description?: string;
};

export type AgentInfo = {
  id: AgentId;
  displayName: string;
  found: boolean;
  path: string | null;
  version: string | null;
};

export type UpdateDiff = {
  currentSha: string;
  latestSha: string;
  files: Array<{ path: string; before: string; after: string }>;
};
```

---

## 関数一覧

### `inventory` — ツール一覧取得

```typescript
export function inventory(params: {
  storagePath: string;
  projectPath: string | null;
}): Promise<InventoryItem[]>;
```

- `projectPath` が `null` の場合はユーザー全体のみ返す
- 走査は 180 秒キャッシュ。手動更新・書き込み直後・View 非表示で破棄する
- frontmatter は先頭 4 KB だけ読む。本文は詳細表示中のみ保持する

---

### `scanPath` — AI エージェント CLI の検知

```typescript
export function scanPath(): Promise<AgentInfo[]>;
```

- ログインシェル（`$SHELL -l -c 'echo $PATH'`）で PATH を解決する
- Windows では `powershell -Command $env:PATH` を使う

---

### `add` — Skill / Subagent / Plugin 追加

```typescript
export function add(params: {
  storagePath: string;
  url: string;
  kind: 'skill' | 'subagent' | 'plugin';
  scope: ScopeId;
  projectPath?: string;
}): Promise<void>;
```

- `scope === 'project'` の場合は `projectPath` が必須
- `Fetcher` → `Installer` → WriteGuard のパスを通る
- zip 展開は `yauzl` 等の npm パッケージを使用（`ditto` は廃止）

---

### `remove` — ツール削除

```typescript
export function remove(params: {
  storagePath: string;
  selector: Selector;
}): Promise<void>;
```

- Undo は廃止。呼び出し前に確認ダイアログを表示する（拡張側の責務）
- WriteGuard を通す。失敗時は `AgentToolError` を throw して何も変更しない

---

### `toggle` — 有効化 / 無効化

```typescript
export function toggle(params: {
  storagePath: string;
  selector: Selector;
}): Promise<{ enabled: boolean }>;
```

---

### `updatePreview` — 更新差分プレビュー

```typescript
export function updatePreview(params: {
  storagePath: string;
  selector: Selector;
}): Promise<UpdateDiff>;
```

- 返却した本文は `TextDocumentContentProvider` に渡して Diff Editor で開き、Editor を閉じたら破棄する

---

### `updateApply` — 更新適用

```typescript
export function updateApply(params: {
  storagePath: string;
  selector: Selector;
}): Promise<{ appliedSha: string }>;
```

- 適用中に失敗した場合は同一呼び出し内でロールバックする

---

### `mcpAdd` — MCP サーバー追加

```typescript
export function mcpAdd(params: {
  storagePath: string;
  agent: AgentId;
  scope: ScopeId;
  server: McpServerDefinition;
  projectPath?: string;
}): Promise<void>;
```

---

### `mcpRemove` — MCP サーバー削除

```typescript
export function mcpRemove(params: {
  storagePath: string;
  agent: AgentId;
  name: string;
  scope: ScopeId;
  projectPath?: string;
}): Promise<void>;
```

---

### `mcpStatus` — MCP プロセス状態取得

```typescript
export function mcpStatus(params: {
  agents: AgentId[];
}): Promise<Record<string, boolean>>;  // key: "agent:serverName"
```

- View 表示中に 3 秒ポーリングで呼ぶ。View 非表示・dispose で停止する
- プロセス検出コマンドは OS ごとに分岐する:
  - macOS / Linux: `pgrep -x <name>`
  - Windows: `tasklist /FI "IMAGENAME eq <name>.exe"`

---

### `preview` — URL 解析（インストール前プレビュー）

```typescript
export function preview(params: {
  url: string;
}): Promise<PreviewCandidate[]>;
```

---

### `pluginAdd` — Plugin 追加

```typescript
export function pluginAdd(params: {
  storagePath: string;
  agent: AgentId;
  name: string;
  url?: string;
}): Promise<void>;
```

---

### `migrate` — ManageArms からの移行

```typescript
export function migrate(params: {
  storagePath: string;
  sourcePath: string;
}): Promise<{ migratedEntries: number; skipped: number }>;
```

- `sourcePath` は旧 ManageArms の Application Support ディレクトリを渡す
- 移行先に既存データがある場合は `MIGRATION_CONFLICT` を throw する

---

## 実装メモ

- `storagePath` は `context.globalStorageUri.fsPath` で得る。OS 別パスは VS Code API が解決する（手動分岐不要）
- 180 秒キャッシュは拡張のメモリのみ。手動更新・書き込み直後・View 非表示で破棄する
- すべての書き込みは `src/writeGuard.ts` を経由する（設計決定 D-9）
- Registry の read-modify-write は `src/registry.ts` の `withRegistryLock()` 内で行う（設計決定 D-7）
- zip 展開・ダウンロードの一時ファイルは `os.tmpdir()` に置き、`try/finally` で確実に削除する

---

---

## 参考 — 旧 Swift CLI JSON API（廃止済み）

> 以下は Swift CLI サブプロセス時代（〜2026-09-10）の仕様。TypeScript 移行後は使用しない。

### 旧 呼び出し規約

```
agent-tool-core <command>
```

- **入力**: JSON を stdin に渡す
- **出力**: JSON を stdout に書く
- **終了コード**: 成功 `0`、失敗 `1`

### 旧 共通レスポンス形式

```json
{ "ok": true,  "protocolVersion": "1", "data": {} }
{ "ok": false, "protocolVersion": "1", "error": { "code": "WRITE_GUARD_DENIED", "message": "..." } }
```

### 旧 コマンド入出力（代表例）

**inventory 入力**:
```json
{ "storagePath": "/path/to/globalStorageUri", "projectPath": "/path/to/project" }
```

**add 入力**:
```json
{ "storagePath": "...", "url": "https://github.com/example/my-skill", "scope": "user", "kind": null }
```

**remove 出力**（undo フィールドを含む — 廃止）:
```json
{
  "ok": true, "protocolVersion": "1",
  "data": {
    "undo": {
      "originalPath": "/Users/yuuki/.agents/skills/my-skill",
      "trashedPath": "/Users/yuuki/.Trash/my-skill",
      "registryEntry": { "name": "my-skill", "kind": "skill", "repo": "...", "sha": "abc123" }
    }
  }
}
```

**mcp-status 入力**:
```json
{ "storagePath": "...", "projectPath": "..." }
```

完全な旧 JSON 仕様は git 履歴を参照のこと。
