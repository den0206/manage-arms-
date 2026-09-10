const { strict: assert } = require("node:assert");
const { existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { extract, identify, safeJoin, singleTopLevel, stage } = require("../out/fetcher.js");
const { archiveUrl, parseUrl } = require("../out/github.js");
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

test("zipball の URL を組み立てる", () => {
  assert.equal(archiveUrl({ repo: "o/r" }), "https://github.com/o/r/archive/refs/heads/main.zip");
  assert.equal(archiveUrl({ repo: "o/r" }, "main", "abc"), "https://github.com/o/r/archive/abc.zip");
});

// --- Zip Slip ---

test("展開先の外へ出るパスを弾く", () => {
  const root = "/tmp/unpack";
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
