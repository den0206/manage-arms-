# Agent Tool — データ・ロック仕様

## 保存先

可変メタデータは VS Code の `globalStorageUri` に置く `registry.json` だけとする。
管理対象の Skill と Subagent の実体はエージェントが読む既知の管理ルートに置く。

## `registry.json`

`schemaVersion` は `"1"`。保持するのは 3 つだけ:

| キー | 内容 |
|---|---|
| `resources` | 管理下の Skill / Subagent（名前、種別、取得元、SHA、固定、無効化、project スコープのパス） |
| `repos` | 取得元ごとの最新 SHA と確認日時（`checkUpdates` が書き、`hasUpdate` が読む） |
| `agents` | エージェント CLI の手動パス指定 |

自動検出できるもの、使用実績、除外リストは持たない。
未知の将来スキーマは `SCHEMA_UNSUPPORTED` として拒否し、既定値と同じフィールドは書き出さない。

## ロックと書き込み

`registry.ts` は `registry.lock` を `O_EXCL` で作成してプロセス間排他を行う。
書き込みは一時ファイルを `rename` してアトミックに確定し、ロックは `finally` で削除する。

## 管理ルート

| ルート | 用途 |
|---|---|
| `~/.agents/skills/` | 管理対象 Skill の実体 |
| `<globalStorageUri>/disabled-skills/` | 無効化した Skill |
| `<globalStorageUri>/agents/` | 管理対象 Subagent の実体 |
| `<globalStorageUri>/disabled-agents/` | 無効化した Subagent |

`writeGuard.ts` は名前、親ディレクトリ、リンク先、管理ルートを検証してから作成、移動、削除する。
macOS/Linux では symlink、Windows では junction または hardlink を使う。

## 資源管理

- 一覧キャッシュはメモリだけに保持し、手動更新、書き込み後、View 非表示で破棄する。
- ダウンロード、展開、staging は OS の一時ディレクトリに作り、`finally` で削除する。
- HTTP キャッシュ、ログ、診断履歴、Undo スナップショットを保存しない。
