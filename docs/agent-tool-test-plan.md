# Agent Tool — テスト計画

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> CLI コマンド仕様は [agent-tool-cli-api.md](agent-tool-cli-api.md) を参照。

---

## 1. 方針

Swift CLI は廃止。全テストを TypeScript（Node.js）に統一する。

| 層 | ツール | 実行タイミング |
|---|---|---|
| WriteGuard / Registry / Installer 純粋ロジック（偽ホーム） | Node.js `node:test` | 全 PR |
| DashboardProvider・拡張コマンド（VS Code API モック） | Node.js `node:test` | 全 PR |
| E2E（Cursor Stable + 実モジュール） | `@vscode/test-electron` | 全 PR |
| 手動確認（実機） | — | リリース前 |

**書かないテスト**: UI スナップショット、モックを検証するだけのテスト。

---

## 2. TypeScript モジュールテスト

Node.js `node:test` を使う。実ユーザーのホームに到達しないよう、
すべてのテストで偽ホームを使う。

### 2.1 偽ホームのセットアップ

```typescript
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function withFakeHome(fn: (home: string) => Promise<void>): Promise<void> {
  const home = mkdtempSync(join(tmpdir(), 'agent-tool-test-'));
  return fn(home).finally(() => rmSync(home, { recursive: true }));
}
```

### 2.2 優先テスト項目

#### WriteGuard — 名前検証

```typescript
test('パストラバーサル名を拒否する', () => {
  assert.throws(() => assertValidName('../evil'), /INVALID_NAME/);
  assert.throws(() => assertValidName('.hidden'), /INVALID_NAME/);
  assert.throws(() => assertValidName('a/b'), /INVALID_NAME/);
});
```

#### WriteGuard — 作成ガード

```typescript
test('管理ルート外を指す親 symlink を拒否する', async () => {
  await withFakeHome(async home => {
    // ~/.claude -> /outside のような symlink を作ってから assertSafeCreation を呼ぶ
    await assert.rejects(() => assertSafeCreation(dest, managedRoots), /SYMLINK_OUTSIDE_STORE/);
  });
});
```

#### Registry — プロセス間ロック

```typescript
test('並行書き込みが直列化される', async () => {
  await withFakeHome(async home => {
    const storagePath = join(home, 'storage');
    fs.mkdirSync(storagePath, { recursive: true });
    // 2 つの withRegistryLock を同時に実行し、後発が待機することを確認
    const results: number[] = [];
    await Promise.all([
      withRegistryLock(storagePath, async () => { results.push(1); await delay(50); results.push(2); }),
      withRegistryLock(storagePath, async () => { results.push(3); }),
    ]);
    assert.deepEqual(results, [1, 2, 3]);
  });
});
```

#### Installer — `add` の往復

```typescript
test('Skill を追加して inventory に現れる', async () => {
  await withFakeHome(async home => {
    // 偽 GitHub レスポンスを注入して add → inventory の往復を確認
  });
});
```

#### Installer — `migrate`

```typescript
test('旧フィールドを除去して schemaVersion を付ける', async () => {
  await withFakeHome(async home => {
    // browserDetection / menuBar / appearance が消え、schemaVersion: "1" が付くこと
    // resources / repos が保持されること
  });
});
```

#### Windows 分岐 — junction / hardlink

```typescript
test('Windows では Skill を junction、Subagent を hardlink で張る', async () => {
  // platform を 'win32' にモックしてリンク種別の選択を確認する
});

test('別ボリュームへの hardlink 失敗を OPERATION_FAILED にする', async () => {
  // コピーへフォールバックしないことを確認する
});
```

実際に junction / hardlink を作れるかは Windows ランナーで検証する（設計決定 D-10）。

### 2.3 走査範囲テスト（設計の生命線）

走査ホワイトリスト（`Source` 列挙相当）の外を読まないことを確認する。
`projectPath` の外を走査しないことをテストする。

---

## 3. 拡張コマンド・DashboardProvider ユニットテスト

Node.js `node:test` を使い、VS Code API をモックして拡張ロジックを検証する。

| テスト対象 | 内容 |
|---|---|
| `globalStorageUri` の受け渡し | 各操作に `storagePath` が含まれること |
| Remote 環境ガード | `vscode.env.remoteName` が非 null のとき書き込みを拒否すること |
| 未信頼ワークスペースガード | `workspace.isTrusted === false` のとき書き込みを拒否すること |
| MCP ポーリング | View 表示中のみ 3 秒タイマーが動くこと |
| メモリ解放 | View 非表示時に watcher、タイマー、キャッシュを破棄すること |
| HTTP 応答上限 | レスポンスボディが 2 MB で打ち切られること |

---

## 4. E2E テスト（Cursor Stable + 実モジュール）

`@vscode/test-electron` の `runTests` に固定バージョンの Cursor Stable 実行ファイルを
`vscodeExecutablePath` として渡す。ツールの既定ダウンロード先である VS Code は使わない。
Cursor の取得 URL と SHA-256 は CI 設定に固定し、macOS の全 PR で回す。
（Swift CLI は廃止のため「実 CLI」ではなく実モジュールで動作する）

### 4.1 必須シナリオ

| シナリオ | 検証内容 |
|---|---|
| Tree View の表示 | Current Project と User Global の両セクションが表示される |
| PATH 検知 | `claude` が見つかりバージョンが表示される |
| ツール追加 | GitHub URL から Skill を追加し Tree View に現れる |
| ツール削除 | 確認後に削除され、Dashboard から消える |
| 有効化/無効化 | トグル後に ✓ / ✗ が切り替わる |
| 更新プレビュー | Diff Editor が開く |
| 更新適用 | 更新後に SHA が変わる |
| MCP ステータス | 起動中サーバーが `●`、停止中が `○` で表示される |
| 初回移行 | 旧 `registry.json` を検知して移行ダイアログが出る |
| 未信頼ワークスペース | バナーが表示され書き込みボタンが無効 |

### 4.2 E2E のセットアップ

```bash
# 偽ホームを使って実ユーザーのファイルに触れない
export AGENT_TOOL_HOME=$(mktemp -d)
mkdir -p "$AGENT_TOOL_HOME/.claude/commands"
```

TypeScript モジュールは `AGENT_TOOL_HOME` を `os.homedir()` の代わりに使う。
このフックは E2E とモジュールテストだけで設定し、通常起動では `os.homedir()` を使う。

---

## 5. 互換性テスト

| 対象 | PR |
|---|---|
| モック CLI でのコマンド動作 | ✓ |
| 実 AgentToolCore CLI での統合 | ✓ |
| `protocolVersion` 不一致の検出 | ✓ |
| 旧 `registry.json` スキーマの読み込み | ✓ |

---

## 6. 手動確認項目（自動化しない）

| 項目 | 理由 |
|---|---|
| ダークモード / ライトモードでの Tree View 表示 | 実機でしか確認できない |
| 複数 Cursor ウィンドウ同時操作でのロック動作 | プロセス間制御は実機で確認 |
| 配布VSIXの初回起動 | 最初の公開前と、VSIX組み立て・配布経路を変えた場合にCursorからインストールして確認 |
| RSS・保存容量 | リリース前に閾値内であることを実測 |

---

## 7. CI 構成

Swift テストは廃止。3 OS の単体テスト・不変条件検査・Cursor E2E の 3 ジョブで回す。
Windows は junction / hardlink が実機でしか検証できないため必須にする（設計決定 D-10）。

```yaml
# .github/workflows/ci.yml

jobs:
  test:                      # ubuntu / windows / macos の matrix
    steps:
      - run: npm ci
      - run: npm run typecheck
      - run: npm test        # node:test — WriteGuard / Registry / 走査 / 取得 / 拡張コマンド

  invariants:                # ubuntu
    steps:
      - run: ./scripts/check-invariants.sh
      - run: ./scripts/release-changelog.sh --check
      - run: ./scripts/test-release-changelog.sh

  cursor:                    # macos。Cursor Stable は macOS でのみ起動する
    steps:
      - run: npm run package
      - run: npm run test:cursor
      - # VSIX 20 MB 上限チェック
```

全ジョブを PR ゲートにする。定期 canary は設けない。
