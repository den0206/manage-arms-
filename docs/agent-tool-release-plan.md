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
2. VSIX を一度だけ組み立て、SHA-256 を記録する。
3. Open VSX に公開する。
4. 同じ VSIX を GitHub Release に添付する。

Open VSX への公開に失敗した場合は GitHub Release を作らない。
