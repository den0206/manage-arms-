# Agent Tool — リリース計画

## 現在の構成

- 拡張機能と管理ロジックは TypeScript で実装する。
- `ide/` `browser/` `core/` に分け、`test/` はルートに集約する。
- ルートの `package.json` は 1 つ。ブラウザ拡張は `browser/manifest.json` を持つ。
- VSIX は Node.js 依存だけを含み、サイズ上限は 20 MB とする。
- `scripts/` にローカルと CI で共通の検査スクリプトを置く。

版は拡張ごとに独立させる。リリースはタグの接頭辞で分岐する。

| タグ | 対象 |
|---|---|
| `ide-v<semver>` | VSIX を組み立てて Open VSX と GitHub Release へ |
| `browser-v<semver>` | ブラウザ拡張の zip を組み立てて GitHub Release へ |

`CHANGELOG.md` は 1 つのまま、`[Unreleased]` の中で対象ごとに見出しを分ける。

## リリース前の確認

```bash
npm run typecheck
npm test
./scripts/check-invariants.sh
./scripts/release-changelog.sh --check
./scripts/test-release-changelog.sh
npm run package
```

Cursor Stable の E2E を実行し、VSIX のサイズが 20 MB 未満であることも確認する。

## 配布

1. `release/Ver_<semver>` ブランチで検査を通す。
2. push時に `.github/workflows/release.yml` が検査し、VSIXを一度だけ組み立ててSHA-256を記録する。
3. 安定版は `OVSX_PAT` が設定されている場合だけOpen VSXに公開する。
4. 同じVSIXとSHA-256をGitHub Releaseに添付する。

Open VSX の公開を実行して失敗した場合は、Workflowを停止してGitHub Releaseを作らない。alpha / betaはGitHub Releasesだけに公開する。

## ブラウザ拡張の配布

1. `browser-v<semver>` のタグで zip を組み立て、SHA-256 を記録する。
2. Chrome Web Store へ提出する。
3. Edge Add-ons へ同じ zip を提出する。
4. Brave は Chrome Web Store からの導入を案内し、Chrome と同じ zip を手動確認する。
5. 同じ zip と SHA-256 を GitHub Release に添付する。

ストア審査は `host_permissions` の用途説明を求められる。要求するのは github.com /
skills.sh / agentsdirectory.dev の 3 つだけで、`<all_urls>` は要求しない。
