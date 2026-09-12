#!/usr/bin/env node
// 任意の実サイト確認。CI には入れない: カタログ側の障害で通常テストを落とさない。
// 取り込むのはブラウザ向けの ESM 出力なので、このスクリプトも ESM にする
// （Node 20 は ESM を require できない）。
import assert from "node:assert/strict";
import { firstUnwritable } from "../out/web/core/archive.js";
import { lead, proofUrls } from "../out/web/core/detect.js";
import { download } from "../out/web/browser/install.js";
import { fromJsonLd, needsPage } from "../out/web/core/github.js";
import { PAGE_LIMIT } from "../out/web/core/limits.js";
import { placement, targets } from "../out/web/core/placement.js";

const text = async url => {
  const response = await fetch(url, { cache: "no-store" });
  assert.ok(response.ok, `${url}: ${response.status}`);
  return response.text();
};
const pick = values => values[Math.floor(Math.random() * values.length)];
const matches = (body, pattern) => [...body.matchAll(pattern)].map(match => match[1]);
const isRejectedCatalog = error => error?.kind === "notFound" || error?.kind === "tooLarge";
const githubSkills = ["composition-patterns", "react-view-transitions", "web-design-guidelines"];
// Subagent はカタログに出ないので、GitHub の実リポジトリを固定で見る。消えたら赤くする
// （固定物の差し替えが要る、と気づける方がよい）。
const githubSubagents = ["code-refactorer", "content-writer", "frontend-designer", "vibe-coding-coach"];

const sites = [
  ["GitHub", async () => `https://github.com/vercel-labs/agent-skills/tree/main/skills/${pick(githubSkills)}`],
  ["GitHub (subagent)", async () =>
    `https://github.com/iannuttall/claude-agents/blob/main/agents/${pick(githubSubagents)}.md`],
  ["skills.sh", async () => {
    const maps = matches(await text("https://www.skills.sh/sitemap.xml"), /<loc>([^<]*sitemap-skills[^<]*)<\/loc>/g);
    assert.ok(maps.length > 0, "skills.sh: no skill sitemap found");
    const urls = matches(await text(pick(maps)), /<loc>(https:\/\/[^<]+)<\/loc>/g);
    assert.ok(urls.length > 0, "skills.sh: no skill URL found");
    return pick(urls);
  }],
  ["Agents Directory", async () => {
    const paths = [...new Set(matches(await text("https://agentsdirectory.dev/skills"), /href="(\/skills\/[^"?#]+)"/g))];
    assert.ok(paths.length > 0, "Agents Directory: no skill URL found");
    for (let left = Math.min(paths.length, 12); left > 0; left--) {
      const index = Math.floor(Math.random() * paths.length);
      const url = `https://agentsdirectory.dev${paths.splice(index, 1)[0]}`;
      const source = fromJsonLd(await text(url));
      if (source !== null && lead(source) !== null) return url;
    }
    throw new Error("Agents Directory: no installable skill URL found");
  }],
];

async function resolve(url) {
  if (needsPage(url) === null) return url;
  const response = await fetch(url, { cache: "no-store" });
  assert.ok(response.ok, `${url}: ${response.status}`);
  return fromJsonLd((await response.text()).slice(0, PAGE_LIMIT));
}

void (async () => {
  for (const [site, randomUrl] of sites) {
    attempts:
    for (let attempt = 1; attempt <= 12; attempt++) {
      let url;
      let found;
      try {
        url = await randomUrl();
        found = lead(await resolve(url));
      } catch (error) {
        if (error instanceof TypeError) {
          console.log(`skip ${site}: network unavailable`);
          break attempts;
        }
        throw error;
      }
      assert.ok(found !== null, `${site}: no installable tool found`);
      try {
        for (const proof of proofUrls(found)) {
          const response = await fetch(proof, { method: "HEAD", cache: "no-store" });
          if (response.status !== 200) {
            if (attempt === 12) assert.fail(`${site}: ${proof}: ${response.status}`);
            console.log(`skip ${site}: ${proof} → ${response.status}`);
            continue attempts;
          }
        }
        const { files } = await download(found);
        assert.ok(files.length > 0, `${site}: no files extracted`);
        assert.ok(files.some(file => file.path === (found.kind === "skill" ? "SKILL.md" : `${found.name}.md`)),
          `${site}: tool entry was not extracted`);
        // 「検知はするが導入で落ちる」を実機なしで捕まえる。FSA の書き込みは試せないが、
        // 3 OS のどこかで作れない名前が入っていないかは取得結果だけで分かる。
        const bad = firstUnwritable([found.name, ...files.map(file => file.path)]);
        assert.equal(bad, null, `${site}: ${bad} cannot be written on every system`);
        const agent = targets(found.kind)[0];
        assert.ok(placement(agent, found.kind, found.name, false) !== null, `${site}: no destination`);
        console.log(`ok ${site}: ${url} → ${found.kind} ${found.name}`);
        break;
      } catch (error) {
        if (error instanceof TypeError) {
          console.log(`skip ${site}: network unavailable`);
          break attempts;
        }
        if (found.proofs.length !== 0 || !isRejectedCatalog(error) || attempt === 12) throw error;
        console.log(`skip ${site}: ${url} → ${error.kind}`);
      }
    }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
