const { strict: assert } = require("node:assert");
const { existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { tmpdir } = require("node:os");
const { test } = require("node:test");
const { extract, fetchPage, identify, safeJoin, singleTopLevel, stage } = require("../out/ide/fetcher.js");
const { PAGE_LIMIT } = require("../out/core/limits.js");
const { archiveUrl, catalog, fromJsonLd, needsPage, parseUrl, skillHint } = require("../out/core/github.js");
const { fakeEnv, makeDir, writeFileIn } = require("./helpers.js");
const { writeZip } = require("./zipFixture.js");

const code = expected => error => error.code === expected;

// --- GitHub URL ---

test("リポジトリ URL を読む", () => {
  assert.deepEqual(parseUrl("https://github.com/owner/repo"), { repo: "owner/repo" });
  assert.deepEqual(parseUrl("https://github.com/owner/repo.git"), { repo: "owner/repo" });
});

/** ブランチ名に "/" を含むと境界が確定できない。曖昧であることを持って返す。 */
test("tree 以下はブランチとサブディレクトリに割り、曖昧さを残す", () => {
  assert.deepEqual(parseUrl("https://github.com/owner/repo/tree/main/skills/pdf"),
    { repo: "owner/repo", branch: "main", subdir: "skills/pdf", branchAmbiguous: true });
  assert.deepEqual(parseUrl("https://github.com/owner/repo/tree/main"),
    { repo: "owner/repo", branch: "main", subdir: undefined, branchAmbiguous: false });
});

test("GitHub 以外と壊れた URL は受け取らない", () => {
  assert.equal(parseUrl("https://example.com/owner/repo"), null);
  assert.equal(parseUrl("https://github.com/owner"), null);
  assert.equal(parseUrl("https://github.com/owner/repo/raw/main"), null);
  assert.equal(parseUrl("https://github.com/own er/repo"), null);
  assert.equal(parseUrl("not a url"), null);
});

// --- カタログサイト ---

test("URL に owner/repo を含むカタログはネットワークに触れず解決する", () => {
  assert.deepEqual(parseUrl("https://www.skills.sh/anthropics/skills/frontend-design"),
    { repo: "anthropics/skills" });
  assert.equal(skillHint("https://skills.sh/anthropics/skills/frontend-design"), "frontend-design");
  assert.equal(needsPage("https://skills.sh/anthropics/skills/frontend-design"), null);
  assert.equal(catalog("https://skills.sh/agent/claude-code"), null);   // 予約パス
});

test("URL だけで決まらないカタログはページの URL を返す", () => {
  assert.equal(needsPage("https://agentsdirectory.dev/skills/frontend-design/"),
    "https://agentsdirectory.dev/skills/frontend-design/");
  assert.equal(needsPage("agentsdirectory.dev/skills/frontend-design"),
    "https://agentsdirectory.dev/skills/frontend-design");
  assert.equal(catalog("https://agentsdirectory.dev/skills/frontend-design/"), null);
  assert.equal(needsPage("https://example.com/skills/x"), null);        // 対応外のサイト
});

/** HTML の構造は見ない。読むのは schema.org の codeRepository / url だけ。 */
test("JSON-LD から取得元の URL を拾う", () => {
  const block = body => `<script type="application/ld+json">${body}</script>`;
  assert.equal(
    fromJsonLd(block(JSON.stringify([{ "@type": "SoftwareApplication",
      url: "https://www.skills.sh/anthropics/skills/frontend-design" }]))),
    "https://www.skills.sh/anthropics/skills/frontend-design");
  assert.equal(
    fromJsonLd(block(JSON.stringify({ "@graph": [{ codeRepository: "https://github.com/o/r" }] }))),
    "https://github.com/o/r");
  // 壊れたブロックで打ち切らず、後ろのブロックを読む
  assert.equal(fromJsonLd(block("{ broken") + block(JSON.stringify({ url: "https://github.com/o/r" }))),
    "https://github.com/o/r");
  // 自分自身や対応外の URL は解決にならない
  assert.equal(fromJsonLd(block(JSON.stringify({ url: "https://agentsdirectory.dev/skills/x" }))), null);
  assert.equal(fromJsonLd("<html>https://github.com/o/r</html>"), null);
});

test("カタログページは上限を超えたら読まない", async () => {
  const oversize = { ok: true, headers: { get: () => String(PAGE_LIMIT + 1) }, body: { cancel: async () => {} } };
  await assert.rejects(fetchPage("https://agentsdirectory.dev/skills/x", async () => oversize),
    code("FETCH_FAILED"));
  const missing = { ok: false, status: 404, headers: { get: () => null } };
  await assert.rejects(fetchPage("https://agentsdirectory.dev/skills/x", async () => missing),
    code("FETCH_FAILED"));
});

test("Content-Length がなくても読み込み中にページ上限を打ち切る", async () => {
  let cancelled = false;
  const chunk = new Uint8Array(1024 * 1024);
  const response = {
    ok: true,
    headers: new Map(),
    body: {
      cancel: async () => { cancelled = true; },
      async *[Symbol.asyncIterator]() { yield chunk; yield chunk; yield chunk; },
    },
  };
  await assert.rejects(fetchPage("https://agentsdirectory.dev/skills/x", async () => response),
    code("FETCH_FAILED"));
  assert.equal(cancelled, true);
});

test("zipball の URL を組み立てる", () => {
  assert.equal(archiveUrl({ repo: "o/r" }), "https://github.com/o/r/archive/refs/heads/main.zip");
  assert.equal(archiveUrl({ repo: "o/r" }, "main", "abc"), "https://github.com/o/r/archive/abc.zip");
});

// --- Zip Slip ---

test("展開先の外へ出るパスを弾く", () => {
  const root = join(tmpdir(), "unpack");
  assert.equal(safeJoin(root, "../evil"), null);
  assert.equal(safeJoin(root, "a/../../evil"), null);
  assert.equal(safeJoin(root, "/etc/passwd"), join(root, "etc/passwd"));  // 先頭の / は落ちる
  assert.equal(safeJoin(root, "a\\b"), null);
  assert.equal(safeJoin(root, "C:/evil"), null);
  assert.equal(safeJoin(root, "ok/file.md"), join(root, "ok/file.md"));
});

// --- extract ---

test("zip を展開する", async () => {
  const env = fakeEnv();
  const archive = writeZip(join(makeDir(env.home), "a.zip"), [
    { name: "repo-main/SKILL.md", data: "---\nname: pdf\n---\n" },
  ]);
  const out = join(env.home, "out");
  await extract(archive, out);
  assert.ok(readFileSync(join(out, "repo-main", "SKILL.md"), "utf8").includes("name: pdf"));
});

/** アーカイブ 1 つで管理ルートの外へ書かれないこと。 */
test("展開先の外を指すエントリを拒否する", async () => {
  const env = fakeEnv();
  const archive = writeZip(join(makeDir(env.home), "evil.zip"), [
    { name: "../escaped.md", data: "x" },
  ]);
  await assert.rejects(extract(archive, join(env.home, "out")), code("FETCH_FAILED"));
  assert.equal(existsSync(join(env.home, "escaped.md")), false);
});

test("symlink を含むアーカイブを拒否する", async () => {
  const env = fakeEnv();
  const archive = writeZip(join(makeDir(env.home), "link.zip"), [
    { name: "repo-main/evil", data: "/etc/passwd", unixMode: 0o120777 },
  ]);
  await assert.rejects(extract(archive, join(env.home, "out")), /symbolic link/);
});

// --- 種別判定 ---

test("SKILL.md があれば Skill として拾う", () => {
  const env = fakeEnv();
  const base = makeDir(join(env.home, "pdf"));
  writeFileIn(join(base, "SKILL.md"), "---\nname: pdf\ndescription: d\n---\n");
  assert.deepEqual(identify(base).map(c => [c.kind, c.name, c.description]), [["skill", "pdf", "d"]]);
});

/** frontmatter の name は取得先が書いた文字列。使えない名前はディレクトリ名に落とす。 */
test("パスに使えない name はディレクトリ名に落とす", () => {
  const env = fakeEnv();
  const base = makeDir(join(env.home, "safe"));
  writeFileIn(join(base, "SKILL.md"), "---\nname: ../../evil\n---\n");
  assert.equal(identify(base)[0].name, "safe");
});

test("tools を持つ .md は Subagent として拾う", () => {
  const env = fakeEnv();
  const base = makeDir(join(env.home, "agents"));
  writeFileIn(join(base, "reviewer.md"), "---\nname: reviewer\ntools: Read\n---\n");
  writeFileIn(join(base, "README.md"), "---\nname: readme\n---\n");   // tools 無しは候補にしない
  assert.deepEqual(identify(base).map(c => [c.kind, c.name]), [["subagent", "reviewer"]]);
});

test("skills/<category>/<name> の配置まで辿る", () => {
  const env = fakeEnv();
  const base = makeDir(join(env.home, "repo"));
  writeFileIn(join(base, "skills", "docs", "pdf", "SKILL.md"), "---\nname: pdf\n---\n");
  assert.deepEqual(identify(base).map(c => c.name), ["pdf"]);
});

test("zipball の 1 段目を剥がす", () => {
  const env = fakeEnv();
  const root = makeDir(join(env.home, "unpacked"));
  makeDir(join(root, "repo-main"));
  assert.equal(singleTopLevel(root), join(root, "repo-main"));
});

// --- ダウンロードの上限 ---

test("Content-Length が上限を超えていれば本文を読まない", async () => {
  let cancelled = false;
  const fetchImpl = async () => ({
    ok: true,
    status: 200,
    headers: new Map([["content-length", String(60 * 1024 * 1024)]]),
    body: { cancel: async () => { cancelled = true; } },
  });
  await assert.rejects(stage({ repo: "o/r" }, { fetchImpl }), /too large/);
  assert.equal(cancelled, true);
});

/** Content-Length が返らない場合の保険。 */
test("書き込み量でも上限を打ち切る", async () => {
  const chunk = new Uint8Array(1024 * 1024);
  const fetchImpl = async () => ({
    ok: true,
    status: 200,
    headers: new Map(),
    body: (async function* () { for (let i = 0; i < 60; i++) yield chunk; })(),
  });
  await assert.rejects(stage({ repo: "o/r" }, { fetchImpl }), /too large/);
});

test("HTTP エラーは FETCH_FAILED にする", async () => {
  const fetchImpl = async () => ({ ok: false, status: 404, headers: new Map() });
  await assert.rejects(stage({ repo: "o/r" }, { fetchImpl }), code("FETCH_FAILED"));
});
