# Agent Tool — TypeScript モジュール API 仕様

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> プロダクト要件は [product-requirements.md](product-requirements.md) を参照。

実装の入口は `src/agentTool.ts`。

---

## 呼び出し規約

すべての操作は `src/agentTool.ts` が export する非同期関数として提供する。

- **入出力**: TypeScript の型付きオブジェクト（JSON シリアライズ不要）
- **失敗**: `AgentToolError` を throw する（`code` フィールドで種別を判定）
- **storagePath**: `context.globalStorageUri.fsPath` を渡す（OS 別パスは VS Code API が解決）
- **バージョン**: プロセス境界が無いので拡張とロジックの版ずれは起きない。
  互換判定は `registry.json` の `schemaVersion` だけが持つ（`src/registry.ts`）

---

## エラー型

```typescript
// src/agentTool.ts
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
  projectPath?: string;     // scope === 'project' のときのワークスペース
};

export type InventoryItem = {
  name: string;
  kind: KindId;
  scope: ScopeId;
  agents: AgentId[];       // 複数エージェントで共有する場合がある
  enabled: boolean;
  origin: 'managed' | 'user' | 'bundled';
  sourcePath?: string;     // 実体の場所。詳細表示でそのまま見せる
  repoUrl?: string;
  hasUpdate: boolean;
  pinned: boolean;         // 更新を追わないと利用者が決めたもの
  summary?: string;        // frontmatter の先頭 4 KB から取得
  mcpScope?: 'user' | 'project' | 'local';    // MCP の登録先。削除コマンドの -s に載る
  pluginScope?: 'user' | 'project' | 'local'; // Plugin の登録先
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
  currentSha: string | null;   // 初回取得時は記録が無い
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
  user?: boolean;            // 省略時は true。false ならユーザー全体を走査しない
}): Promise<{ items: InventoryItem[]; issues: string[] }>;
```

- `projectPath` が `null` の場合はユーザー全体のみ返す
- `user: false` は他プロジェクト欄向け。Skill / Subagent / MCP の user 走査をせず、Plugin も `projectPath` 一致だけを返す
- Plugin は CLI が全プロジェクト分を返すので、`projectPath` と一致しない project スコープは一覧に載せない
- `issues` は走査に失敗したエージェントの理由。1 つのエージェントの失敗で一覧全体を落とさない
- プロジェクトのサブディレクトリにあるスキルは `apps/web:deploy` の修飾名で返す（名前で畳むため）
- 走査は 180 秒キャッシュ。手動更新・書き込み直後・View 非表示で破棄する
- frontmatter は先頭 4 KB だけ読む。本文は詳細表示中のみ保持する

---

### `projects` — 他プロジェクト欄の候補

```typescript
export function projects(params: {
  storagePath: string;
}): string[];
```

- `~/.claude.json` の `projects` キーだけを読む。ホームは走査しない
- 実在し、直下に Skill / Subagent / `.mcp.json` / local MCP のいずれかがあるパスだけを返す

---

### `checkUpdates` — 最新 SHA の確認

```typescript
export function checkUpdates(params: {
  storagePath: string;
}): Promise<{ checked: number; issues: string[] }>;
```

- 管理下の取得元ごとに GitHub の HEAD を引き、`registry.repos[<repo>#<branch>]` に
  `latestSha` と `checkedAt` を書く。`hasUpdate` はこの記録だけで決まる
- 固定中（`pinned`）の取得元は問い合わせない
- 定期ポーリングは持たない。明示的な操作（`agent-tool.checkUpdates`）でだけ走る
- 失敗した取得元は `issues` に理由を入れ、成功した分の記録は残す

---

### `togglePin` — 更新の固定

```typescript
export function togglePin(params: {
  storagePath: string;
  selector: Selector;
}): Promise<{ pinned: boolean }>;
```

registry に取得元があるものだけ。固定中は `hasUpdate` にも `checkUpdates` にも載せない。

---

### `watchPaths` — 監視対象のパス

```typescript
export function watchPaths(params: {
  storagePath: string;
  projectPath: string | null;
}): string[];
```

`source.ts` の走査ホワイトリストとワークスペースの `.claude/skills`・`.claude/agents`・`.mcp.json` を返す。
Dashboard は View 表示中だけこれを `createFileSystemWatcher` に渡す。ホームやワークスペース全体は監視しない。

---

### `isSupportedUrl` — 解析できる URL か

```typescript
export function isSupportedUrl(url: string): boolean;
```

クリップボードの内容を提案してよいかの判定に使う。純粋関数でネットワークに触れない。

---

### `scanPath` — AI エージェント CLI の検知

```typescript
export function scanPath(params: {
  storagePath: string;
}): Promise<AgentInfo[]>;
```

- ログインシェル（`$SHELL -l -c 'echo $PATH'`）で PATH を解決する
- Windows では `powershell -Command $env:PATH` を使う
- 手動指定した CLI パス（`registry.agents[agent].path`）があればそれを優先する
- Dashboard の Environment 欄がこれを表示する。手動更新のときだけ引き直す

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
- `scope === 'project'` は `projectPath` が要る。user と project の同名は別の実体として扱う

---

### `toggle` — 有効化 / 無効化

```typescript
export function toggle(params: {
  storagePath: string;
  selector: Selector;
}): Promise<{ enabled: boolean }>;
```

- user スコープだけ。project は退避先を持たないので `isTogglable` が false になる

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
  server: MCPServer;
}): Promise<void>;
```

追加先は user スコープだけ（各 CLI に `-s user` を載せる）。

---

### `mcpRemove` — MCP サーバー削除

```typescript
export function mcpRemove(params: {
  storagePath: string;
  agent: AgentId;
  name: string;
  /** 登録先。CLI の `-s` にそのまま載る。 */
  scope: 'user' | 'project' | 'local';
}): Promise<void>;
```

`scope` は一覧が読み取った登録先（`InventoryItem.mcpScope`）をそのまま渡す。
`ScopeId` に潰すと `project` と `local` の区別が消え、同名の user サーバーを消す。

---

### `mcpStatus` — MCP プロセス状態取得

```typescript
export function mcpStatus(params: {
  storagePath: string;
}): Promise<Record<string, boolean>>;  // key: "agent:serverName"
```

- View 表示中に 3 秒ポーリングで呼ぶ。View 非表示・dispose で停止する
- 判定方式は「全プロセスを 1 回取得し、registry の MCP 定義（`command` + `args`）と突き合わせ、
  親プロセスを辿って所有 Agent を決める」（設計決定 D-8）。プロセス名の一致では判定しない
- 取得コマンドは OS ごとに分岐する:
  - macOS / Linux: `ps -eo pid,ppid,etime,command`
  - Windows: `powershell -NoProfile -Command "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,CreationDate,CommandLine | ConvertTo-Json"`
- 出力は 2 MB で打ち切る

---

### `preview` — URL 解析（インストール前プレビュー）

```typescript
export function preview(params: {
  url: string;
}): Promise<{ url: string; candidates: PreviewCandidate[] }>;
```

- 受ける URL は `src/github.ts` の `CATALOG_SITES` が宣言するサイトと GitHub。追加・削除は 1 エントリ
- `owner/repo` を URL に含まないカタログはページを 1 回読み、schema.org の JSON-LD にある
  `codeRepository` / `url` だけを使って取得元を決める。HTML は走査しない（ページ上限 2 MB）
- 返す `url` は解決後のもの。`add` に渡すと同じページを読み直さない

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

- URL が渡された場合は Marketplace を登録してから Plugin を追加する
- Claude は `plugin install`、Codex は `plugin add` を使う

### `pluginRemove` — Plugin 削除

```typescript
export function pluginRemove(params: {
  storagePath: string;
  agent: AgentId;
  name: string;
  scope?: 'user' | 'project' | 'local';
  bundled?: boolean;
}): Promise<void>;
```

Claude の削除には一覧から取得した `scope` をそのまま渡す。Marketplace は他の Plugin と共有できるため削除しない。

---

## 実装メモ

- `storagePath` は `context.globalStorageUri.fsPath` で得る。OS 別パスは VS Code API が解決する（手動分岐不要）
- 180 秒キャッシュは拡張のメモリのみ。手動更新・書き込み直後・View 非表示で破棄する
- ファイル書き込みは `src/writeGuard.ts`（実体・リンク）、`src/registry.ts`（`registry.json`）、
  `src/mcpScanner.ts`（`mcp.json`）の 3 経路だけに置く（設計決定 D-9）
- Registry の read-modify-write は `src/registry.ts` の `withRegistryLock()` 内で行う（設計決定 D-7）
- zip 展開・ダウンロードの一時ファイルは `os.tmpdir()` に置き、`try/finally` で確実に削除する

---

---
