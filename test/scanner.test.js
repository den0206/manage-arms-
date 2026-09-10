const { strict: assert } = require("node:assert");
const { symlinkSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { parse, read, HEAD_BYTES } = require("../out/frontmatter.js");
const { scanSkillRoot, scanSubagentRoot, isLoadable } = require("../out/skillScanner.js");
const { stripComments } = require("../out/mcpScanner.js");
const { parseAll, redact, summary, floatingPackage } = require("../out/mcpServer.js");
const { projectSkillRoots } = require("../out/projectScan.js");
const { fakeEnv, makeDir, writeFileIn } = require("./helpers.js");

const skill = (root, name, body) => writeFileIn(join(root, name, "SKILL.md"), body);

// --- frontmatter ---

test("name と description を読む", () => {
  const result = parse("---\nname: pdf\ndescription: Fill forms\n---\nbody\n");
  assert.equal(result.status, "parsed");
  assert.equal(result.matter.name, "pdf");
  assert.equal(result.matter.description, "Fill forms");
});

/** 実在するスキルの大半がブロックスカラー形式。 */
test("YAML ブロックスカラーを畳む", () => {
  const folded = parse("---\ndescription: >-\n  first\n  second\n---\n");
  assert.equal(folded.matter.description, "first second");
  const literal = parse("---\ndescription: |\n  first\n  second\n---\n");
  assert.equal(literal.matter.description, "first\nsecond");
});

test("引用符を外す", () => {
  assert.equal(parse("---\nname: \"pdf\"\n---\n").matter.name, "pdf");
});

/** 本文中の `---` を閉じと取り違えない。 */
test("行全体が --- のものだけを閉じとみなす", () => {
  const result = parse("---\nname: a\ndescription: x --- y\n---\n");
  assert.equal(result.matter.description, "x --- y");
});

test("先頭が --- でなければ missing", () => {
  assert.equal(parse("# title\n").status, "missing");
});

/** 4 KB しか読まない設計の副作用。description 無しと混同しない。 */
test("閉じ --- が無ければ truncated", () => {
  assert.equal(parse("---\nname: a\n").status, "truncated");
});

test("先頭 4 KB だけを読む", () => {
  const env = fakeEnv();
  const path = writeFileIn(join(env.home, "big", "SKILL.md"),
    "---\nname: big\n" + "#".repeat(HEAD_BYTES) + "\n---\n");
  assert.equal(read(path).status, "truncated");
});

/** 4 KB 境界が日本語の途中に落ちても U+FFFD を出さない。 */
test("末尾で切れた UTF-8 を文字にしない", () => {
  const env = fakeEnv();
  const filler = "あ".repeat(1000);                       // 3 バイト文字で境界をまたがせる
  const path = writeFileIn(join(env.home, "ja", "SKILL.md"),
    `---\ndescription: ${filler}\n---\n`);
  const result = read(path);
  assert.ok(!JSON.stringify(result).includes("\\ufffd"));
});

// --- skill / subagent scanner ---

test("SKILL.md の無いディレクトリは noSkillFile", () => {
  const env = fakeEnv();
  const root = makeDir(join(env.home, "skills"));
  makeDir(join(root, "empty"));
  const [found] = scanSkillRoot(root, ".claude/skills");
  assert.equal(found.status, "noSkillFile");
  assert.equal(isLoadable(found.status), false);
});

test("リンク切れは brokenLink として出す", () => {
  const env = fakeEnv();
  const root = makeDir(join(env.home, "skills"));
  symlinkSync(join(env.home, "gone"), join(root, "dangling"), "junction");
  const [found] = scanSkillRoot(root, ".claude/skills");
  assert.equal(found.status, "brokenLink");
  assert.equal(isLoadable(found.status), false);
});

test("隠しディレクトリとただのファイルは対象外", () => {
  const env = fakeEnv();
  const root = makeDir(join(env.home, "skills"));
  makeDir(join(root, ".system"));
  writeFileIn(join(root, "README.md"), "x");
  skill(root, "pdf", "---\nname: pdf\ndescription: d\n---\n");
  assert.deepEqual(scanSkillRoot(root, ".claude/skills").map(s => s.name), ["pdf"]);
});

/** 識別子はファイル名。frontmatter の name とズレると実体を見失う。 */
test("Subagent の名前はファイル名から取る", () => {
  const env = fakeEnv();
  const root = makeDir(join(env.home, "agents"));
  writeFileIn(join(root, "reviewer.md"), "---\nname: other\ndescription: d\n---\n");
  const [found] = scanSubagentRoot(root, ".claude/agents");
  assert.equal(found.name, "reviewer");
  assert.equal(found.description, "d");
});

// --- MCP ---

/** 文字列の中の `//` をコメント開始と読むと URL を壊す。 */
test("JSONC のコメントだけを落とす", () => {
  const text = '{\n  // note\n  "url": "http://127.0.0.1:3845/mcp" /* trail */\n}';
  assert.deepEqual(JSON.parse(stripComments(text)), { url: "http://127.0.0.1:3845/mcp" });
});

test("stdio と http の両形式を読む", () => {
  const servers = parseAll({
    mcpServers: {
      b: { command: "npx", args: ["-y", "pkg"] },
      a: { type: "http", url: "https://example.com/mcp" },
    },
  });
  assert.deepEqual(servers.map(s => s.name), ["a", "b"]);   // 名前順
  assert.equal(servers[0].transport.type, "http");
  assert.equal(servers[1].transport.command, "npx");
});

test("型の合わない定義は読み飛ばす", () => {
  assert.deepEqual(parseAll({ mcpServers: { bad: { command: "npx", args: "oops" } } }), []);
});

test("エージェント管理のサーバーは保護する", () => {
  const [server] = parseAll({ mcpServers: { a: { command: "x", isBuiltIn: true } } });
  assert.equal(server.isProtected, true);
});

/** シークレットは要約に出さない。 */
test("要約からトークンを落とす", () => {
  assert.deepEqual(redact(["--token", "abc", "--api-key=xyz", "plain"]),
    ["--token", "[redacted]", "--api-key=[redacted]", "plain"]);
  const [http] = parseAll({ mcpServers: { a: { url: "https://u:p@example.com/mcp?key=1" } } });
  const text = summary(http);
  assert.ok(!text.includes("key=1") && !text.includes("u:p"), text);
});

test("@latest 指定を拾う", () => {
  const [server] = parseAll({ mcpServers: { a: { command: "npx", args: ["-y", "pkg@latest"] } } });
  assert.equal(floatingPackage(server), "pkg");
});

// --- project scan ---

test("プロジェクトの .claude/skills を深さ 3 まで探す", () => {
  const env = fakeEnv();
  const project = makeDir(join(env.home, "proj"));
  skill(join(project, ".claude/skills"), "root-skill", "---\nname: a\n---\n");
  skill(join(project, "apps/web/.claude/skills"), "nested", "---\nname: b\n---\n");
  skill(join(project, "a/b/c/d/.claude/skills"), "too-deep", "---\nname: c\n---\n");
  skill(join(project, "node_modules/pkg/.claude/skills"), "vendored", "---\nname: d\n---\n");
  assert.deepEqual(projectSkillRoots(project).map(found => found.prefix).sort(), ["", "apps/web"]);
});
