---
name: add-catalog-site
description: Agent Tool の検知・導入対応サイトを1つ増やす。カタログサイトの URL を渡されたとき、IDE 拡張とブラウザ拡張の両方で検知・導入・削除・一覧が同じように動く状態まで、テストごと仕上げる。「対応サイトを増やす」「このサイトに対応して」「add a catalog site」やカタログ URL を渡されたときに使う。
---

# 対応サイトを増やす

渡された URL のサイトを、GitHub / skills.sh / Agents Directory と**同じ扱い**にする。

## 絶対に外さない2点

1. **IDE 拡張とブラウザ拡張で差が出ない。** 判定は `core/github.ts` だけに置く。
   どちらか片方にしか無い分岐を作らない。
2. **自動テストを必ず書く。** 既存サイトと同じ場所に、同じ粒度で足す。
   「実機で見た」は完了条件にしない。

## 1. まずサイトを調べる（ここを飛ばさない）

URL の形で作り方が2つに分かれる。**実際に取得して確かめる**。憶測で決めない。

```bash
# (a) URL に owner/repo が入っているか
#     例 https://skills.sh/vercel-labs/agent-skills/react-best-practices → 入っている
# (b) 入っていなければ、ページの JSON-LD に取得元があるか
SITE_HTML=$(mktemp)
trap 'rm -f "$SITE_HTML"' EXIT
curl -sL "<渡された URL>" -o "$SITE_HTML" -w "code=%{http_code} bytes=%{size_download}\n"
grep -c 'application/ld+json' "$SITE_HTML"
grep -o 'codeRepository[^,]*\|github\.com/[A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*' "$SITE_HTML" | head
```

| 調べた結果 | 作り方 |
|---|---|
| URL に `owner/repo` が入っている | `fromPath` を書く。ネットワークに触れず解決できる |
| 入っていないが JSON-LD に `codeRepository` か `url` がある | `fromPath` を**書かない**。`needsPage` → `fromJsonLd` に載る |
| どちらも無い | **対応できない。** ページの HTML を漁る実装は足さない（構造の変更で静かに壊れる）。ここで止めて利用者に伝える |

`grep -c 'application/ld+json'` が **0 を返したら要注意**。IDE 拡張は `fetchPage` で
**サーバの HTML** を読み、ブラウザ拡張は content script で**描画後の DOM** を読む。
サーバ側に無くクライアントで注入されるサイトは、**ブラウザだけ動いて IDE が落ちる**。
その場合は対応できないものとして扱う。これが差分の一番出やすいところである。

## 2. 変更する場所

順に全部やる。1つでも欠けると片方の拡張だけ壊れる。

| ファイル | 何を足すか |
|---|---|
| `core/github.ts` | `CATALOG_SITES` に1エントリ。`{ host, label, fromPath? }` |
| `browser/manifest.json` | `host_permissions` と `content_scripts[].matches` に `https://<host>/*` と `https://www.<host>/*` の**両方** |
| `test/fetcher.test.js` | `parseUrl` / `needsPage` / `catalog` / `skillHint`（IDE 側の解決） |
| `test/browserCore.test.js` | `lead` / `detectPage`、末尾の一覧表、`SUPPORTED_SITES` |
| `test/agentTool.test.js` | `isSupportedUrl` |
| `scripts/test-browser-catalogs.mjs` | `sites` に1件（実サイトの手動確認） |
| `README.md` / `README.ja.md` | 対応サイトの表。**日英を同時に** |
| `CHANGELOG.md` | `[Unreleased]` に**英語**で1行 |

`SUPPORTED_SITES` は `CATALOG_SITES` から自動で導かれる。手で足さない。

### `fromPath` を書くときの注意

`RESERVED` は **skills.sh 専用**の予約パス集合である。別サイトの予約語をここへ混ぜない。
そのサイト固有の除外が要るなら、そのサイトの `fromPath` の中に閉じて書く。

`fromPath` は `url.pathname.split("/")` の結果を受ける。**percent-encode されたまま**なので、
デコードが要るなら自分で行い、`isRepoPath` を必ず通してから `repo` に入れる。

## 3. 差分を出さないための確認

`core/` に置けば自動的に揃う。揃わないのは次の3つだけなので、ここだけ見る。

| 確認 | やり方 |
|---|---|
| manifest の到達範囲 | `npm run package:browser`。`CATALOG_SITES` と manifest の突き合わせが走る |
| JSON-LD の在り処 | 上の `grep -c 'application/ld+json'`。サーバ HTML に無ければ非対応 |
| カタログ名 ≠ ディレクトリ名 | 実体の `SKILL.md` の frontmatter `name` と突き合う。IDE は `identify`、ブラウザは `locateSkill`。**両方のテストを書く** |

## 4. テスト（必須）

既存サイトの書き方をそのまま真似る。新しい型を作らない。

```bash
npm test                          # 固定フィクスチャ。ネットワークに触れない
npm run test:browser-catalogs     # 手動: 実サイトで追加したサイトを確認する
```

`test/browserCore.test.js` の「対応サイトの複数 Tool を検知し、導入先を選べる」にある
`fixtures`（サイト名・URL・種別・名前）へ行を足すのが最小の追加になる。
**同じサイトから2件**入れる（1件だと URL の形ではなく偶然で通ることがある）。
Subagent を出すサイトなら Subagent の行も足す。

## 5. 完了条件

```bash
npm run typecheck && npm test
./scripts/check-invariants.sh
npm run package:browser
npm run test:browser-catalogs     # 手動確認
```

固定テストとパッケージ検査が緑になってから報告する。`test:browser-catalogs` は実サイトを
叩く手動確認なので、失敗・スキップ時は URL と理由を明示し、こちらの問題かサイト側かを
切り分けてから伝える。

## やらないこと

- ページの HTML 構造に依存した抽出（`<div class="...">` を読む等）。静かに壊れる
- `<all_urls>` の要求。ホストは必要な分だけ
- IDE 拡張とブラウザ拡張で別々の判定を書くこと
- テストを後回しにして「実機で確認した」で済ませること
