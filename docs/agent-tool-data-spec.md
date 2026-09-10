# Agent Tool — データ・ロック・移行仕様

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> CLI コマンド仕様は [agent-tool-cli-api.md](agent-tool-cli-api.md) を参照。

---

## 1. ストレージ構成

### 1.1 永続データ

| ファイル | パス | 役割 |
|---|---|---|
| `registry.json` | `<globalStorageUri>/registry.json` | 唯一の可変メタデータ。全管理リソースの出所・状態 |
| `registry.lock` | `<globalStorageUri>/registry.lock` | 内容を持たないプロセス間ロック inode |
| `agents/` | `<globalStorageUri>/agents/` | 管理対象 Subagent の実体 |
| `disabled-skills/` / `disabled-agents/` | `<globalStorageUri>/` | 無効化した管理対象実体の退避先 |

**`globalStorageUri`** の実パスは Cursor が OS 別に管理する。VS Code API の `context.globalStorageUri.fsPath` で取得する（手動構築不要）。

| OS | `globalStorageUri` の実パス |
|---|---|
| macOS | `~/Library/Application Support/Cursor/User/globalStorage/yuuki-sakai.agent-tool/` |
| Linux | `~/.config/Cursor/User/globalStorage/yuuki-sakai.agent-tool/` |
| Windows | `%APPDATA%\Cursor\User\globalStorage\yuuki-sakai.agent-tool\` |

**CLI ストレージ（appSupport）** のパスは `context.globalStorageUri.fsPath` を使うためこの表と一致する。別途 `~/Library/Application Support/AgentTool/` などを参照する必要はない。

### 1.2 一時ファイル

| 用途 | 場所 | 生存期間 |
|---|---|---|
| ダウンロード・zip 展開 | `path.join(os.tmpdir(), 'agent-tool-fetch-<uuid>')` | `try/finally` で削除（成功・失敗・キャンセル全経路） |
| 削除 Undo 情報 | 廃止（確認ダイアログに一本化） | — |

永続キャッシュ、ログ、診断履歴、Undo スナップショットは持たない。Skill / Subagent の実体は
管理対象データであり、キャッシュには数えない。

---

## 2. `registry.json` スキーマ

### 2.1 現行（ManageArms）との差分

| フィールド | ManageArms | Agent Tool | 理由 |
|---|---|---|---|
| `schemaVersion` | なし | 追加 (`"1"`) | 将来の破壊的移行を検出するため |
| `resources` | あり | 維持 | 管理リソースの中核 |
| `repos` | あり | 維持 | 更新状態（ETag・SHA） |
| `usage` | あり | 維持 | 最終使用日時 |
| `projects` | あり | 維持 | 追跡プロジェクト一覧 |
| `agents` | あり | 維持 | エージェントごとの手動設定 |
| `excludedProjects` | あり | 維持 | 走査除外プロジェクト |
| `browserDetection` | あり | **削除** | Mac App 機能。拡張版では廃止 |
| `menuBar` | あり | **削除** | Mac App 機能。拡張版では廃止 |
| `appearance` | あり | **削除** | Mac App 機能。拡張版では廃止 |

### 2.2 完全スキーマ（Agent Tool v1）

```json
{
  "schemaVersion": "1",
  "resources": [
    {
      "name": "my-skill",
      "kind": "skill",
      "repo": "https://github.com/example/my-skill",
      "branch": "main",
      "subdir": null,
      "sha": "abc123def456",
      "pinned": false,
      "disabled": false
    }
  ],
  "repos": {
    "https://github.com/example/my-skill@main": {
      "etag": "\"33a64df5\"",
      "latestSha": "def456abc123",
      "checkedAt": "2026-09-10T10:00:00Z"
    }
  },
  "usage": {
    "scannedUpTo": "2026-09-10T09:00:00Z",
    "lastUsed": {
      "my-skill": "2026-09-09T15:30:00Z"
    },
    "scannedSources": {
      "usageLog/claude": "2026-09-10T09:00:00Z"
    }
  },
  "projects": [
    "/Users/yuuki/my-project"
  ],
  "agents": {
    "claude": {
      "enabled": true,
      "path": null
    }
  },
  "excludedProjects": []
}
```

### 2.3 書き込み規則

- **アトミック書き込み**: `tmp` ファイルに書いてから `fs.rename(tmp, dest)` で置き換える。書き込み中のクラッシュで壊れない
- **フォーマット**: pretty-printed JSON、キーをソートする（diff が読みやすい）
- **日付**: ISO 8601 形式
- **存在しないキーは省略**: 既定値と変わらないフィールドは書き出さない（ファイルを汚染しない）
- **欠損キーは既定値で補完**: `decodeIfPresent` を使い、古いスキーマのファイルを読んでも落ちない

---

## 3. プロセス間排他ロック

### 3.1 必要な理由

現行の `NSLock` はプロセス内スレッドを守るだけ。
拡張版では複数の Cursor ウィンドウが同時に CLI を起動しうるため、**プロセス間ロック**が必要。

### 3.2 ロック方式: `O_EXCL` フラグによる原子的生成（TypeScript）

```typescript
// registry.ts 内の実装（agent-tool-security.md § 6 と同じ）
async function withRegistryLock<T>(storagePath: string, fn: () => Promise<T>): Promise<T> {
  const lockPath = path.join(storagePath, 'registry.lock');
  const deadline = Date.now() + 10_000;
  while (true) {
    try {
      const fd = fs.openSync(lockPath, 'wx');  // O_CREAT | O_EXCL — 原子的生成
      fs.closeSync(fd);
      break;
    } catch (e: any) {
      if (e.code !== 'EEXIST') throw e;
      // stale ロック判定：mtime が 30 秒超なら削除して再試行
      try {
        const stat = fs.statSync(lockPath);
        if (Date.now() - stat.mtimeMs > 30_000) { fs.unlinkSync(lockPath); continue; }
      } catch {}
      if (Date.now() >= deadline) throw new AgentToolError('LOCK_TIMEOUT', 'Registry lock timeout');
      await new Promise(r => setTimeout(r, 50));
    }
  }
  try { return await fn(); }
  finally { try { fs.unlinkSync(lockPath); } catch {} }
}
```

**特性:**
- `O_EXCL` は macOS / Linux / Windows の全 OS で同一動作する
- プロセスクラッシュ時は `registry.lock` が残る（stale ロック）が、30 秒後に自動回収する
- `flock()` や npm `proper-lockfile` は使わない（Windows 互換のため）
- タイムアウト 10 秒を超えたら `LOCK_TIMEOUT` エラーを返す

### 3.3 ロック取得のスコープ

| 操作 | ロック必要 | 理由 |
|---|---|---|
| `inventory` | 不要（読み取り専用） | 一覧取得は競合しても安全 |
| `toggle` | **必要** | read-modify-write |
| `remove` | **必要** | read-modify-write + ファイル削除 |
| `add` | **必要** | read-modify-write + ファイル作成 |
| `update-apply` | **必要** | read-modify-write + ファイル上書き |
| `mcp-add/remove` | **必要** | MCP 設定ファイルの read-modify-write |
| `scan-path` | 不要 | 読み取りだけ |
| `migrate` | **必要** | 新規書き込み |

---

## 4. WriteGuard の維持

WriteGuard の全不変条件を `writeGuard.ts` モジュール内に維持する。`writeGuard.ts` の外からファイルを操作しない。

### 4.1 拒否対象（変更なし）

**ファイル名の拒否リスト:**
```
auth.json, oauth_creds.json, settings.json, settings.local.json,
.claude.json, config.toml, mcp.json
```

**拡張子の拒否リスト:**
```
sqlite, sqlite-wal, sqlite-shm
```

### 4.2 検査の流れ（操作ごと）

```
add / install
  └── assertValidName(name)          // ../・/・隠しファイルを含む名前を拒否
  └── assertSafeCreation(dest, ...)  // 親ディレクトリに不審な symlink がないか

remove / toggle
  └── assertMutable(url, ...)        // ホワイトリスト確認
      ├── assertNotBundled           // バンドル済みスキルを守る
      ├── isDenied(url)              // 拒否リストを二重確認
      ├── symlink → target が managedRoots 内か
      └── registry.json に載っているか
```

### 4.3 管理ルートの定義（Agent Tool 版）

Mac App の Application Support の代わりに `globalStorageUri` を `env.appSupport` として渡す。
現行 Core の配置を保った `env.managedRoots` は以下とする:

| ルート | 説明 |
|---|---|
| `~/.agents/skills/` | 管理対象 Skill の実体。Cursor / Codex が直接読む |
| `<globalStorageUri>/disabled-skills/` | 無効化した Skill の退避先 |
| `<globalStorageUri>/agents/` | 管理対象 Subagent の実体 |
| `<globalStorageUri>/disabled-agents/` | 無効化した Subagent の退避先 |

`~/.claude/skills/`、`~/.claude/agents/`、`~/.cursor/agents/` には上記実体への symlink だけを置く。
プロジェクト内の `.claude/skills/` と `.claude/agents/` は管理ストアではなくユーザー資産なので、
操作直前に `assertUserArtifact` で検証する。

`globalStorageUri/registry.json` は WriteGuard の管理対象外。CLI が直接管理する。

---

## 5. 初回移行フロー

### 5.1 検知条件

TS 拡張の起動時（`activate`）に以下を確認する:

```typescript
const legacyPath = path.join(
  os.homedir(),
  "Library/Application Support/ManageArms/registry.json"
);
const migrated = context.globalState.get<boolean>("migrationDone");

if (fs.existsSync(legacyPath) && !migrated) {
  // 確認画面を表示して migrate コマンドを呼ぶ
}
```

### 5.2 移行ステップ

```
1. TS 拡張が確認ダイアログを表示
   「ManageArms のデータを Agent Tool に移行しますか？」
   [移行する] [後で] [移行しない]

2. [移行する] を選択したら migrate コマンドを実行
   Input:
   {
     "storagePath": "<globalStorageUri>",
     "sourcePath": "~/Library/Application Support/ManageArms"
   }

3. migrate 関数の処理（`installer.ts`）
   a. sourcePath 配下の registry.json を読む
   b. browserDetection / menuBar / appearance を削除
   c. schemaVersion: "1" を追加
   d. resources / repos / usage / projects / agents / excludedProjects をコピー
   e. 旧 agents / disabled-skills / disabled-agents の存在と移行先の競合を先に検査する
   f. registry または実体の移行先が既に存在したら `MIGRATION_CONFLICT` で停止し、上書き・自動マージしない
   g. 管理対象実体を一時ディレクトリへコピーし、検証後に新しい globalStorageUri へ移す
   h. registry.json を最後にアトミック書き込みする
   i. 失敗時は今回作成した移行先だけを除去する。sourcePath は常に残す

4. TS 拡張が context.globalState.set("migrationDone", true) を記録
5. 完了通知を表示し、ManageArms の手動削除を案内する
```

`[後で]` は状態を変えず次回起動時に再表示する。`[移行しない]` は
`migrationDeclined: true` を `globalState` に保存し、自動表示を止める。手動移行コマンドは残す。

### 5.3 移行失敗時の扱い

- `migrationDone` フラグは立てない → 次回起動時に再試行できる
- エラー内容を通知で表示する（registry.json が壊れている場合など）
- 旧ファイルには一切書き込まない

---

## 6. スキーマバージョンアップ

`schemaVersion` は破壊的変更が入ったときだけインクリメントする。
後方互換の追加（フィールド追加）はバージョンを上げない。

| バージョン | 変更内容 |
|---|---|
| `"1"` | 初版。ManageArms の `browserDetection` / `menuBar` / `appearance` を削除 |

### バージョン不一致時の動作

```
CLI が registry.json を読んだとき:
  schemaVersion が自分より新しい → SCHEMA_UNSUPPORTED エラー（拡張の更新を促す）
  schemaVersion が自分より古い → 自動アップグレードして書き直す（後方互換）
  schemaVersion が存在しない    → ManageArms 形式とみなし、移行を促す
```

---

## 7. ストレージ規律まとめ

現行の CLAUDE.md ストレージ規律をそのまま引き継ぐ:

| 規律 | Agent Tool 版での実装 |
|---|---|
| 可変メタデータは 1 つだけ | `registry.json` のみ。管理対象実体以外のログ・スナップショットを作らない |
| キャッシュディレクトリを持たない | CLI 結果は TypeScript のメモリだけに約180秒保持し、View 非表示で破棄 |
| 一時展開は OS に回収させる | `path.join(os.tmpdir(), 'agent-tool-fetch-<uuid>')` + `try/finally` 削除 |
| HTTP キャッシュを生やさない | `fetch()` に `cache: 'no-store'` を指定 |
| 全部読まない | frontmatter は先頭 4 KB のみ読む |
| アトミックに書く | `fs.rename(tmp, dest)` で置き換える |

### メモリとライフサイクル

- 書き込み操作はモジュール関数として完結し、プロセス間キャッシュを持たない
- Tree View は表示用 DTO だけを保持する。ファイル本文を常駐させない
- MCP の3秒ポーリングとファイル監視は View 表示中だけ動かす
- stdout / stderr は各2 MB、HTTP API 応答は2 MBで打ち切る
- アーカイブはメモリに載せず一時ファイルへ流し、50 MBで打ち切る
