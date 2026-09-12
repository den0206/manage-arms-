<p align="center">
  <img src="media/icon.png" width="160" alt="Agent Tool アイコン">
</p>

**Skillを見つけて、かんたん導入！**

# Agent Tool

[![CI](https://github.com/den0206/agent-tool/actions/workflows/ci.yml/badge.svg)](https://github.com/den0206/agent-tool/actions/workflows/ci.yml)
[![GitHub Release](https://img.shields.io/github/v/release/den0206/agent-tool?include_prereleases&sort=semver)](https://github.com/den0206/agent-tool/releases)
[![Open VSX](https://img.shields.io/open-vsx/v/yuuki-sakai/agent-tool)](https://open-vsx.org/extension/yuuki-sakai/agent-tool)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Agent Toolは、AIコーディングエージェントのSkill、Subagent、MCPサーバー、Pluginを横断管理するCursor拡張です。

<p align="center">
  <img src="media/demo.gif" width="1200" alt="Pluginを導入する動作">
</p>

## 概要

コーディングエージェントが使うリソースを、エディタ内の1つの画面から確認・管理できます。各エージェントが対応する配置場所を走査し、エージェントが所有する操作は公式CLIへ委譲します。

## 主な機能

- Skill、Subagent、MCPサーバー、Pluginを1つのダッシュボードで確認
- GitHubと対応カタログからSkill / Subagentを導入
- GitHubサブディレクトリ内のPluginを含むClaude Code / Codex Pluginの導入
- 説明、場所、スコープ、有効状態、更新の確認
- 管理対象ファイルをコピーせず、ユーザー領域とプロジェクト領域を管理
- macOS / Linux / Windowsで動作

## 必要環境

- Node.js 20以降に対応するCursor
- 確認・管理したいエージェントのCLI（Claude Code、Codexなど）
- リモート取得またはPlugin Marketplace登録時のインターネット接続

## インストール

[GitHub Releases](https://github.com/den0206/agent-tool/releases)から`.vsix`ファイルをダウンロードし、次のコマンドでインストールできます。

```bash
code --install-extension agent-tool-X.Y.Z.vsix
# または Cursor で: cursor --install-extension agent-tool-X.Y.Z.vsix
```

拡張機能ビューの「VSIXからのインストール…」も使えます。安定版は[Open VSX](https://open-vsx.org/extension/yuuki-sakai/agent-tool)にも公開します。

## 対応サイト

次のサイトのURLを拡張のURL欄に貼り付けられます。

| サイト                                           | URLの例                                               | 取得元の決め方                                                                 |
| ------------------------------------------------ | ----------------------------------------------------- | ------------------------------------------------------------------------------ |
| [GitHub](https://github.com/)                    | `https://github.com/owner/repo/tree/main/skills/pdf`  | URLから決まります。                                                            |
| [skills.sh](https://skills.sh/)                  | `https://skills.sh/anthropics/skills/frontend-design` | URLから決まります（パスに`owner/repo`を含みます）。                            |
| [Agents Directory](https://agentsdirectory.dev/) | `https://agentsdirectory.dev/skills/frontend-design/` | ページを1回読み、schema.orgのJSON-LDメタデータだけからリポジトリを特定します。 |

サイトは`core/github.ts`の`CATALOG_SITES`で宣言し、追加・削除は1エントリで済みます。ページのHTMLは走査しません。URLに`owner/repo`を含まないサイトは、JSON-LDの`codeRepository`または`url`を公開している必要があります。

## 使い方

1. CursorでAgent Toolを起動し、Activity Barから開きます。
2. ダッシュボードのユーザー全体・プロジェクト欄を確認します。
3. 追加操作から対応するGitHubまたはカタログURLを貼り付けます。
4. 検出されたSkill、Subagent、MCP、Pluginを選び、操作を確認します。
5. 再走査やリモート更新の確認には更新操作を使います。

Pluginの導入はClaude CodeまたはCodexへ委譲します。Claude CodeではMarketplaceを登録してからPluginを導入します。

## 開発

Node.js 20が必要です。

```bash
npm ci
npm run check      # 型検査・テスト・不変条件検査
npm run package
```

拡張のキャッシュはメモリだけに保持します。可変メタデータはCursorの`globalStorageUri`に置く`registry.json`だけとし、一時ダウンロード・展開物は成功・失敗を問わず削除します。

CursorまたはVS CodeでF5を押すと、拡張機能開発ホストを起動できます。

## リリース

`release/Ver_X.Y.Z`という名前のブランチを作成してpushします。GitHub Actionsが検査を実行し、VSIXを1回だけ生成してSHA-256を記録し、GitHub Releaseへ添付します。`OVSX_PAT` Secretを設定した場合、安定版はOpen VSXにも公開します。

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
