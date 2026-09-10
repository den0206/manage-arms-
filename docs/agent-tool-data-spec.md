# Agent Tool — データ・ロック・移行仕様

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> CLI コマンド仕様は [agent-tool-cli-api.md](agent-tool-cli-api.md) を参照。

---

## 1. ストレージ構成

### 1.1 永続ファイル

| ファイル | パス | 役割 |
|---|---|---|
| `registry.json` | `<globalStorageUri>/registry.json` | 唯一の永続ファイル。全管理リソースの出所・状態 |
| `registry.lock` | `<globalStorageUri>/registry.lock` | プロセス間排他ロックファイル |

**`globalStorageUri`** の実パスは Cursor が管理する。
macOS の場合:

```
~/Library/Application Support/Cursor/User/globalStorage/agent-tool.agent-tool/
```

- VS Code の場合は `Cursor` が `Code` に変わる
- TS 拡張は `context.globalStorageUri.fsPath` で取得し、CLI に `storagePath` として渡す

### 1.2 一時ファイル

| 用途 | 場所 | 生存期間 |
|---|---|---|
| ダウンロード・zip 展開 | `FileManager.temporaryDirectory` | CLI プロセス内で `defer` 削除 |
| ロールバックスナップショット | プロセスのメモリのみ | CLI プロセスが生きている間のみ |

永続キャッシュディレクトリは持たない。

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

- **アトミック書き込み**: `Data.write(to:options:.atomic)` を使う。書き込み中のクラッシュで壊れない
- **フォーマット**: pretty-printed JSON、キーをソートする（diff が読みやすい）
- **日付**: ISO 8601 形式
- **存在しないキーは省略**: 既定値と変わらないフィールドは書き出さない（ファイルを汚染しない）
- **欠損キーは既定値で補完**: `decodeIfPresent` を使い、古いスキーマのファイルを読んでも落ちない

---

## 3. プロセス間排他ロック

### 3.1 必要な理由

現行の `NSLock` はプロセス内スレッドを守るだけ。
拡張版では複数の Cursor ウィンドウが同時に CLI を起動しうるため、**プロセス間ロック**が必要。

### 3.2 ロック方式: POSIX アドバイザリロック（`flock`）

```swift
// AgentToolCore 内の実装イメージ
func withRegistryLock<T>(storagePath: URL, _ body: () throws -> T) throws -> T {
    let lockURL = storagePath.appending(path: "registry.lock")
    FileManager.default.createFile(atPath: lockURL.path, contents: nil)
    let fd = open(lockURL.path, O_RDWR)
    defer { close(fd) }

    // 排他ロック取得（最大 10 秒待機）
    var deadline = Date.now.addingTimeInterval(10)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard Date.now < deadline else { throw LockError.timeout }
        Thread.sleep(forTimeInterval: 0.05)
    }
    defer { flock(fd, LOCK_UN) }

    return try body()
}
```

**特性:**
- プロセス終了・クラッシュで自動解放される（ゾンビロックが残らない）
- `registry.lock` ファイル自体は削除しない（削除と再作成が競合するため）
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
| `scan-path` | 不要 | registry を触らない |
| `migrate` | **必要** | 新規書き込み |

---

## 4. WriteGuard の維持

WriteGuard の全不変条件を AgentToolCore CLI 内に維持する。TypeScript 拡張が直接ファイルを操作することはない。

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

Mac App が持つ `env.appSupport`（Application Support）は廃止。
`env.managedRoots` は以下のまま維持する:

| ルート | 説明 |
|---|---|
| `~/.claude/commands/` | Claude Code のスキル実体 |
| `~/.claude/agents/` | Claude Code のサブエージェント実体 |
| `~/.claude/commands/.disabled/` | 無効化されたスキルの退避先 |
| `~/.cursor/commands/` | Cursor のスキル実体 |
| `<project>/.claude/skills/` | プロジェクトローカルのスキル |
| `<project>/.claude/agents/` | プロジェクトローカルのサブエージェント |

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
     "sourcePath": "~/Library/Application Support/ManageArms/registry.json",
     "targetPath": "<globalStorageUri>/registry.json"
   }

3. migrate コマンドの処理（AgentToolCore CLI）
   a. sourcePath の JSON を読む
   b. browserDetection / menuBar / appearance を削除
   c. schemaVersion: "1" を追加
   d. resources / repos / usage / projects / agents / excludedProjects をコピー
   e. targetPath へアトミック書き込み
   f. sourcePath は削除しない（ユーザーが手動で削除）

4. TS 拡張が context.globalState.set("migrationDone", true) を記録
5. 完了通知を表示し、ManageArms の手動削除を案内する
```

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
  schemaVersion が自分より新しい → PROTOCOL_MISMATCH エラー（拡張の更新を促す）
  schemaVersion が自分より古い → 自動アップグレードして書き直す（後方互換）
  schemaVersion が存在しない    → ManageArms 形式とみなし、移行を促す
```

---

## 7. ストレージ規律まとめ

現行の CLAUDE.md ストレージ規律をそのまま引き継ぐ:

| 規律 | Agent Tool 版での実装 |
|---|---|
| 永続ファイルは 1 つだけ | `registry.json` のみ。ログ・スナップショット・キャッシュファイルを作らない |
| キャッシュディレクトリを持たない | CLIScan キャッシュはメモリのみ（約 180 秒、ウィンドウを閉じたら破棄） |
| 一時展開は OS に回収させる | `FileManager.temporaryDirectory` + `defer` 削除 |
| URLSession は `.ephemeral` | HTTP キャッシュファイルを生やさない |
| 全部読まない | frontmatter は先頭 4 KB のみ読む |
| アトミックに書く | `Data.write(to:options:.atomic)` |
