# Agent Tool — リリース計画

## 現在の構成

- 拡張機能と管理ロジックは TypeScript で実装する。
- VSIX は Node.js 依存だけを含み、サイズ上限は 20 MB とする。
- `scripts/` にローカルと CI で共通の検査スクリプトを置く。

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
