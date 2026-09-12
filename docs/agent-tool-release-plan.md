# Agent Tool — リリース計画

## 現在の構成

- 拡張機能と管理ロジックは TypeScript で実装する。
- `ide/` `browser/` `core/` に分け、`test/` はルートに集約する。
- ルートの `package.json` は 1 つ。ブラウザ拡張は `browser/manifest.json` を持つ。
- VSIX は Node.js 依存だけを含み、サイズ上限は 20 MB とする。
- `scripts/` にローカルと CI で共通の検査スクリプトを置く。

IDE拡張とブラウザ拡張は同じ版で配布する。`release/Ver_X.Y.Z` の push で両方を組み立て、
VSIX、ブラウザzip、それぞれのSHA-256を同じGitHub Releaseへ添付する。

`CHANGELOG.md` は 1 つに保つ。

## リリース前の確認

```bash
npm run typecheck
npm test
./scripts/check-invariants.sh
./scripts/release-changelog.sh --check
./scripts/test-release-changelog.sh
npm run package
npm run package:browser
```

Cursor Stable の E2E を実行し、VSIX のサイズが 20 MB 未満であることも確認する。

## 配布

1. `release/Ver_<semver>` ブランチで検査を通す。
2. push時に `.github/workflows/release.yml` が検査し、`package.json` と `browser/manifest.json` を
   ブランチ名と同じ版へそろえ、VSIXとブラウザzipを一度だけ組み立ててSHA-256を記録する。
3. 安定版は `OVSX_PAT` が設定されている場合だけOpen VSXに公開する。
4. VSIX、ブラウザzipとそれぞれのSHA-256を同じGitHub Releaseに添付する。

Open VSX の公開を実行して失敗した場合は、Workflowを停止してGitHub Releaseを作らない。alpha / betaはGitHub Releasesだけに公開する。

## ブラウザ拡張の配布

**最初の配布先は Chrome Web Store とする。** Chrome の公開で Chrome と Brave の利用者へ
案内でき、承認済みの同じ zip を Edge Add-ons にも提出できる。各ストアの審査はそれぞれ受ける。
自前のダウンロードページは持たない。

1. `release/Ver_<semver>` ブランチを push する。workflow が `browser/manifest.json` も同じ版へ更新し、
   `vsix/agent-tool-browser.zip` を同じGitHub Releaseへ添付する。
2. Chrome の `CHROME_CLIENT_ID`、`CHROME_CLIENT_SECRET`、`CHROME_REFRESH_TOKEN`、
   `CHROME_PUBLISHER_ID`、`CHROME_EXTENSION_ID` がすべてGitHub Secretsにあれば、workflowが
   Chrome Web Storeへzipをアップロードして申請する。1つでも未登録ならこの申請だけをスキップする。
   初回はDeveloper Dashboardで2段階認証、ストア掲載、Privacy / Distributionを設定する。
3. Chrome の承認後、同じzipを Edge Add-ons へ Partner Center から提出する。初回の製品作成と掲載情報の設定もここで行う。
4. Brave は Chrome Web Store からの導入を案内し、Chrome と同じ zip を手動確認する
   （`brave://flags` で File System Access API を有効化する案内は拡張内の文言が持つ）。

Edge Add-ons の自動申請は今後行う。Chrome 承認後だけ実行できる明示的なゲートと、Edge の
package upload / publish の両方を完了まで確認する処理を備えてから戻す。

ストア審査は `host_permissions` の用途説明を求められる。要求するのは github.com /
skills.sh / agentsdirectory.dev の 3 つだけで、`<all_urls>` は要求しない。
用途説明とプライバシー診断の回答は [`docs/browser-store-listing.md`](browser-store-listing.md)
に、公開するプライバシーポリシーは [`PRIVACY.md`](../PRIVACY.md) に用意している。

Chrome Web Store APIの呼び出し自体が失敗すると、Open VSX公開とGitHub Releaseの前にworkflowを失敗させる。
各ストアの審査は非同期であり、申請後の審査却下を他方のストアから自動で取り消すことはできない。
