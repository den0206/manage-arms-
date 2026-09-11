# Agent Tool

Agent Toolは、AIコーディングエージェントのSkill、Subagent、MCPサーバー、Pluginを横断管理するCursor拡張です。

AIエージェント用リソースを管理するローカルのエディタ拡張です。macOS / Linux / Windowsで動作します。

## 対応サイト

次のサイトのURLを拡張のURL欄に貼り付けられます。

| サイト | URLの例 | 取得元の決め方 |
|---|---|---|
| [GitHub](https://github.com/) | `https://github.com/owner/repo/tree/main/skills/pdf` | URLから決まります。 |
| [skills.sh](https://skills.sh/) | `https://skills.sh/anthropics/skills/frontend-design` | URLから決まります（パスに`owner/repo`を含みます）。 |
| [Agents Directory](https://agentsdirectory.dev/) | `https://agentsdirectory.dev/skills/frontend-design/` | ページを1回読み、schema.orgのJSON-LDメタデータだけからリポジトリを特定します。 |

サイトは`src/github.ts`の`CATALOG_SITES`で宣言し、追加・削除は1エントリで済みます。ページのHTMLは走査しません。URLに`owner/repo`を含まないサイトは、JSON-LDの`codeRepository`または`url`を公開している必要があります。

## 状態

すべての操作をTypeScript拡張内で実行します。進捗は[リリース計画](docs/agent-tool-release-plan.md)を参照してください。

## 開発

Node.js 20が必要です。

```bash
npm ci
npm run check      # 型検査・テスト・不変条件検査
npm run package
```

拡張のキャッシュはメモリだけに保持します。可変メタデータはCursorの`globalStorageUri`に置く`registry.json`だけとし、一時ダウンロード・展開物は成功・失敗を問わず削除します。

## ドキュメント

- [プロダクト要件](docs/product-requirements.md)
- [設計決定](docs/vscode-cursor-extension-design-questions.md)
- [モジュールAPI](docs/agent-tool-cli-api.md)
- [ストレージと移行](docs/agent-tool-data-spec.md)
- [セキュリティ](docs/agent-tool-security.md)
- [テスト計画](docs/agent-tool-test-plan.md)
- [リリース計画と進捗](docs/agent-tool-release-plan.md)

## ライセンス

[MIT](LICENSE)

[English](README.md)
