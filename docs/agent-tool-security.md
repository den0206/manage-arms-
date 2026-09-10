# Agent Tool — セキュリティ要件

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> WriteGuard の実装詳細は [agent-tool-data-spec.md](agent-tool-data-spec.md) を参照。

---

## 1. 脅威モデル

Agent Tool が守る対象:

| 資産 | 脅威 |
|---|---|
| `~/.claude/`・`~/.cursor/` 配下の設定ファイル | 不正な上書き・削除 |
| `registry.json` | 破損・競合書き込み |
| ユーザーの認証情報（`auth.json` 等） | 誤削除・漏洩 |
| MCP サーバー設定（`mcp.json`） | 不正な書き換え |
| プロジェクト外ファイル | path traversal による到達 |

信頼しない入力源:

- GitHub リポジトリの frontmatter（`name` フィールドが `../` を含む可能性）
- ユーザーが貼り付けた URL
- MCP サーバーの出力（`stdout` / `stderr`）

---

## 2. WriteGuard 不変条件（現行と同等を維持）

Skill / Subagent の実体とリンクに対する書き込み・削除は、すべて `writeGuard.ts` を通す。
`registry.json` は `registry.ts`、`mcp.json` は `mcpScanner.ts` が扱う（§3）。この 3 ファイル以外は `node:fs` の書き込み系 API を呼ばない。

### 2.1 名前検証（`assertValidName`）

取得物の名前（frontmatter の `name`）をパス要素に使う前に検証する:

```
拒否条件:
  - 空文字列 / 256 バイト超
  - "." または ".."
  - "." で始まる（隠しファイル）
  - "/" または "\" を含む
  - ":" を含む
  - 制御文字（改行・NUL 等）を含む
  - 拒否ファイル名リストに一致する
```

### 2.2 削除・移動ガード（`assertMutable`）

許可条件（どちらか一方を満たすこと）:

1. **自分が張ったリンク** — リンク先が `managedRoots` の配下である
   （macOS / Linux は symlink、Windows は junction / hardlink。hardlink は
   `fs.stat` の `ino` がストア内実体と一致することで判定する）
2. **registry.json に記録された実体** — `managedRoots` または退避ディレクトリの配下にある

二重ガード: ホワイトリストを通過しても `deniedNames` / `deniedExtensions` で拒否する。

### 2.3 作成ガード（`assertSafeCreation`）

作成先の親ディレクトリに含まれる symlink / junction が管理ルート外を指していないか検査する。
`~/.claude -> /outside` のような付け替えで管理外への書き込みを防ぐ。

### 2.4 拒否リスト（変更なし）

```
ファイル名: auth.json, oauth_creds.json, settings.json,
           settings.local.json, .claude.json, config.toml, mcp.json

拡張子:     sqlite, sqlite-wal, sqlite-shm
```

`mcp.json` 自体は拒否リストに入っているが、`MCPManager` は JSON を安全に編集する専用パスを持つ。
直接の `removeItem` / `copyItem` は通らない。

---

## 3. 書き込み権限の制限

| 操作 | 書き込み主体 | 禁止事項 |
|---|---|---|
| Skill / Subagent の追加・削除・更新 | `writeGuard.ts` 経由のみ | `writeGuard.ts` の外から `fs.writeFile` / `fs.rename` しない |
| MCP 設定の追加・削除 | `mcpScanner.ts` の専用パスのみ | `mcp.json` の直接上書き禁止 |
| `registry.json` の書き込み | `registry.ts` のみ | 他モジュールは `registry.ts` の API 経由で読み書きする |
| 一時ファイル | `try/finally` で確実に削除 | 残骸を残さない |

全操作の `storagePath` は絶対パスとして検証する。破壊的操作では `selector.sourcePath` を
直接信用せず、最新インベントリと照合して1件に確定してから WriteGuard を通す。

---

## 4. 未信頼ワークスペース

VS Code の `workspace.isTrusted` が `false` の場合:

- **許可**: `inventory` コマンドによる一覧取得（読み取りのみ）
- **禁止**: `add` / `remove` / `toggle` / `update-apply` / `mcp-add` / `mcp-remove`
- UI: 書き込みボタンを無効化し、信頼バナーを表示する（[UI 設計 8.2](agent-tool-ui-design.md#82-未信頼ワークスペース) 参照）

---

## 5. Remote 環境

`vscode.env.remoteName` が非 null（SSH / Dev Container / Codespaces）の場合:

- **すべての操作を禁止**（読み取り含む）
- CLI を起動しない（ローカル Mac のファイルに到達できないため）
- UI: 全 Tree View を無効化してバナー表示（[UI 設計 8.1](agent-tool-ui-design.md#81-remote-環境) 参照）
- CLI から `REMOTE_ENV` エラーが返った場合も同様に扱う

---

## 6. プロセス間ロック

複数 Cursor ウィンドウの同時書き込みを防ぐ:

- **方式**: `fs.openSync(lockPath, 'wx')` の `O_EXCL` フラグで原子的にロックファイルを生成する
- **タイムアウト**: 10 秒。50 ms ポーリングで再試行し、超過したら `LOCK_TIMEOUT` エラーを返す
- **解放**: 正常終了時は `fs.unlinkSync(lockPath)`。クラッシュで残った stale ロックは mtime が 30 秒超なら削除して再試行する
- **npm `proper-lockfile` は使わない**（Windows でのプロセス死活確認の挙動差を避けるため）

```typescript
// registry.ts 内の実装イメージ
async function withRegistryLock<T>(storagePath: string, fn: () => Promise<T>): Promise<T> {
  const lockPath = path.join(storagePath, 'registry.lock');
  const deadline = Date.now() + 10_000;
  while (true) {
    try {
      const fd = fs.openSync(lockPath, 'wx');
      fs.closeSync(fd);
      break;
    } catch (e: any) {
      if (e.code !== 'EEXIST') throw e;
      // stale ロック判定（30秒超）
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

---

## 7. HTTP 応答のシークレットマスク

`fetch()` の応答テキストは 2 MB で打ち切り、ユーザーへ表示する前に以下のパターンを置換する:

```
--token <value>       → --token [REDACTED]
Authorization: ...    → Authorization: [REDACTED]
Bearer <value>        → Bearer [REDACTED]
```

- raw レスポンスボディはメモリ上でのみ処理し、ディスクに書かない
- エラー通知が閉じたらマスク済み要約も破棄する
- 永続ログは作らない

---

## 8. ダウンロード・取得

- **公開リポジトリのみ・未認証**（初版スコープ）
- `fetch()` に `cache: 'no-store'` を指定する（HTTP キャッシュファイルを生やさない）
- ダウンロード先は `path.join(os.tmpdir(), 'agent-tool-fetch-<uuid>')` とし `try/finally` で削除する
- zip 展開は npm パッケージ（`yauzl` 等）を使い、各エントリに `assertValidName` を適用してから移動する
- GitHub API 応答は 2 MB、アーカイブは 50 MB、展開後は 200 MB、単一ファイルは 20 MB で打ち切る
- アーカイブはメモリへ全量保持せず、`ReadableStream` で一時ファイルへ流す

---

## 9. 拡張の権限スコープ

`package.json` で要求するパーミッション（VS Code Extension Manifest）:

```json
{
  "capabilities": {
    "untrustedWorkspaces": {
      "supported": "limited",
      "description": "未信頼ワークスペースでは一覧表示のみ利用できます"
    },
    "virtualWorkspaces": false
  },
  "extensionKind": ["ui"]
}
```

- `extensionKind: ["ui"]` — ローカル UI Extension として動作。Remote Host では起動しない
- ネットワークアクセス: GitHub API（公開エンドポイント）のみ。外部サービスに認証情報を送らない
- テレメトリ: 一切収集しない

---
