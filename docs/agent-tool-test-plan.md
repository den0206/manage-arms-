# Agent Tool — テスト計画

> 設計の前提は [vscode-cursor-extension-design-questions.md](vscode-cursor-extension-design-questions.md) を参照。
> CLI コマンド仕様は [agent-tool-cli-api.md](agent-tool-cli-api.md) を参照。

---

## 1. 方針

| 層 | ツール | 実行タイミング |
|---|---|---|
| AgentToolCore の純粋関数・ロジック | Swift Testing（既存 375 件） | 全 PR |
| AgentToolCore CLI コマンド（偽ホーム） | Swift Testing（偽環境） | 全 PR |
| TS 拡張 ↔ CLI 統合（モック CLI） | Jest / Vitest | 全 PR |
| E2E（Cursor Stable + 実 CLI） | `@vscode/test-electron` | 日次 CI |
| 手動確認（実機） | — | リリース前 |

**書かないテスト**: UI スナップショット、モックを検証するだけのテスト。

---

## 2. AgentToolCore Swift テスト（既存を維持）

現行 375 件のテストを `AgentToolCore` として維持する。新規 CLI コマンドの追加に伴い以下を追加する。

### 2.1 新規追加テスト

#### `version` コマンド

```swift
@Test func versionOutputsProtocolVersion() throws {
    let out = try runCLI("version", input: "")
    #expect(out["protocolVersion"] as? String == "1")
    #expect(out["ok"] as? Bool == true)
}
```

#### `scan-path` コマンド

```swift
@Test func scanPathReturnsMockedAgents() throws {
    let env = Environment.test(home: fakeHome, which: { name in
        name == "claude" ? "/fake/bin/claude" : nil
    })
    let result = try ScanPath.run(env: env)
    #expect(result.agents.first(where: { $0.id == "claude" })?.found == true)
    #expect(result.agents.first(where: { $0.id == "codex" })?.found == false)
}
```

#### `inventory` コマンド

```swift
@Test func inventoryReturnsProjectAndUserItems() throws {
    // 偽ホームに skill を配置して inventory を呼ぶ
}
```

#### `toggle` / `remove` / `rollback`

```swift
@Test func removeMovesToTrashAndRollbackRestores() throws {
    // remove → trashedPath を確認 → rollback → 元パスに戻ることを確認
}
```

#### WriteGuard の新規検査（CLI エントリポイント経由）

```swift
@Test func addRejectsPathTraversalName() throws {
    #expect(throws: WriteGuard.Denial.invalidName("../evil")) {
        try runCLI("add", input: #"{"url":"...","name":"../evil",...}"#)
    }
}
```

#### プロセス間ロック

```swift
@Test func concurrentWritesSerialize() async throws {
    // 2 プロセスが同時に registry.json を書こうとしたとき、後発が待機することを確認
}
```

#### `migrate` コマンド

```swift
@Test func migrateStripsDeprecatedFields() throws {
    // browserDetection / menuBar / appearance が消えること
    // schemaVersion: "1" が付くこと
    // resources が保持されること
}
```

### 2.2 走査範囲テスト（設計の生命線）

既存のホワイトリストテストを引き継ぐ。
CLI が `projectPath` の外を走査しないことを確認する。

---

## 3. TypeScript 拡張ユニットテスト（Jest / Vitest）

CLI をモック（`jest.mock`）し、TS 拡張のロジックを単体でテストする。

| テスト対象 | 内容 |
|---|---|
| `protocolVersion` チェック | 不一致時に操作を停止すること |
| `globalStorageUri` の受け渡し | 各コマンド入力に `storagePath` が含まれること |
| ロールバックトークンの保持 | `remove` 後の通知に `rollbackToken` が渡されること |
| ファイル監視トリガー | 監視パターンが変化したとき `inventory` が再実行されること |
| Remote 環境ガード | `vscode.env.remoteName` が非 null のとき CLI を起動しないこと |
| 未信頼ワークスペースガード | `workspace.isTrusted === false` のとき書き込みコマンドを呼ばないこと |
| MCP ポーリング | View 表示中のみ 3 秒タイマーが動くこと |

---

## 4. E2E テスト（Cursor Stable + 実 CLI）

`@vscode/test-electron` を使って Cursor Stable 上で実行する。日次 CI で回す。

### 4.1 必須シナリオ

| シナリオ | 検証内容 |
|---|---|
| Tree View の表示 | Current Project と User Global の両セクションが表示される |
| PATH 検知 | `claude` が見つかりバージョンが表示される |
| ツール追加 | GitHub URL から Skill を追加し Tree View に現れる |
| ツール削除 | 削除後に Tree View から消え、ゴミ箱に移動している |
| ロールバック | 削除後に「元に戻す」で復元できる |
| 有効化/無効化 | トグル後に ✓ / ✗ が切り替わる |
| 更新プレビュー | Diff Editor が開く |
| 更新適用 | 更新後に SHA が変わる |
| MCP ステータス | 起動中サーバーが `●`、停止中が `○` で表示される |
| 初回移行 | 旧 `registry.json` を検知して移行ダイアログが出る |
| 未信頼ワークスペース | バナーが表示され書き込みボタンが無効 |

### 4.2 E2E のセットアップ

```bash
# 偽ホームを使って実ユーザーのファイルに触れない
export AGENT_TOOL_HOME=/tmp/agent-tool-e2e-home
mkdir -p $AGENT_TOOL_HOME/.claude/commands
```

---

## 5. 互換性テスト

| 対象 | PR | 日次 |
|---|---|---|
| モック CLI でのコマンド動作 | ✓ | — |
| 実 AgentToolCore CLI での統合 | — | ✓ |
| `protocolVersion` 不一致の検出 | ✓ | — |
| 旧 `registry.json` スキーマの読み込み | ✓ | — |

---

## 6. 手動確認項目（自動化しない）

| 項目 | 理由 |
|---|---|
| `.app` を Finder から起動したときの PATH 解決 | GUI の PATH はターミナルと異なる |
| ダークモード / ライトモードでの Tree View 表示 | 実機でしか確認できない |
| 複数 Cursor ウィンドウ同時操作でのロック動作 | プロセス間制御は実機で確認 |
| 公証済みバイナリの初回実行（Gatekeeper） | `spctl -a -vv` が `accepted` になること |
| ManageArms との同時インストール期間の動作 | 移行期間の実動作確認 |

---

## 7. CI 構成

```yaml
# .github/workflows/ci.yml（既存に追記）

jobs:
  swift-tests:
    runs-on: macos-latest
    steps:
      - swift build
      - swift test                        # 375 件 + 新規 CLI テスト

  ts-tests:
    runs-on: ubuntu-latest
    steps:
      - npm ci
      - npm test                          # Jest / Vitest

  e2e-daily:
    if: github.event_name == 'schedule'
    runs-on: macos-latest
    steps:
      - # Cursor Stable をインストール
      - npm run test:e2e
```

**PR ゲート**: `swift-tests` + `ts-tests`
**日次**: `e2e-daily`（実 CLI 使用）
