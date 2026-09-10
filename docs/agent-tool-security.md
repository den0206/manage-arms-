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

AgentToolCore CLI がすべての書き込み・削除操作の前に通過させる。TypeScript 拡張は直接ファイルを操作しない。

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

1. **自分が張った symlink** — リンク先が `managedRoots` の配下である
2. **registry.json に記録された実体** — `managedRoots` または退避ディレクトリの配下にある

二重ガード: ホワイトリストを通過しても `deniedNames` / `deniedExtensions` で拒否する。

### 2.3 作成ガード（`assertSafeCreation`）

作成先の親ディレクトリに含まれる symlink が管理ルート外を指していないか検査する。
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
| Skill / Subagent の追加・削除・更新 | AgentToolCore CLI のみ | TS 拡張から直接 `fs.writeFile` しない |
| MCP 設定の追加・削除 | `MCPManager`（CLI 内）のみ | `mcp.json` の直接上書き禁止 |
| `registry.json` の書き込み | AgentToolCore CLI のみ | TS 拡張は読み取り専用（globalStorageUri 経由） |
| 一時ファイル | CLI プロセス内の `defer` で管理 | 残骸を残さない |

全コマンドの `storagePath` は絶対パスとして検証する。破壊的操作では `selector.sourcePath` を
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

- **方式**: POSIX `flock()` を `registry.lock` に適用
- **タイムアウト**: 10 秒。超過したら `LOCK_TIMEOUT` エラーを返してユーザーに通知する
- **自動解放**: CLI プロセス終了・クラッシュ時に OS がロックを解放する（ゾンビロックが残らない）

---

## 7. CLI 出力のシークレットマスク

`Exec` 経由の CLI 呼び出しでは stdout / stderr を各2 MBに制限し、以下のパターンを置換する:

```
--token <value>       → --token [REDACTED]
-H Authorization: ... → -H Authorization: [REDACTED]
Bearer <value>        → Bearer [REDACTED]
```

- raw 出力はプロセス終了直後に破棄し、マスク済みの要約だけを通知が閉じるまで保持する
- 永続ログは作らない
- 生の出力はプロセス終了時に破棄する（ディスクに書かない）

---

## 8. ダウンロード・取得

- **公開リポジトリのみ・未認証**（初版スコープ）
- `URLSession.ephemeral` を使う（HTTP キャッシュファイルを生やさない）
- ダウンロード先は `FileManager.temporaryDirectory`（`defer` で削除）
- zip 展開後、`assertValidName` を各エントリに適用してから移動する
- GitHub API 応答は2 MB、アーカイブは50 MB、展開後は200 MB、単一ファイルは20 MBで打ち切る
- アーカイブはメモリへ全量保持せず、一時ファイルへ流す

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

## 10. 既存 Mac App との競合防止

- 旧 `registry.json`（`~/Library/Application Support/ManageArms/`）は **読み取りのみ**参照する
- 移行完了まで旧ファイルへの書き込みは行わない
- 移行後、旧ファイルの削除はユーザーに委ねる（自動削除しない）
- Mac App の追加リリースや移行告知は行わない
- `add` / `remove` / `toggle` / `update-apply` / `mcp-add` / `mcp-remove` / `migrate` の直前に ManageArms の実行中プロセスを確認する
- 実行中なら `LEGACY_APP_RUNNING` で拒否し、終了後の再実行を求める
