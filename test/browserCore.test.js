const { test } = require("node:test");
const assert = require("node:assert/strict");
const { kindOf, lead, proofUrls } = require("../out/core/detect.js");
const { placement, rootOf, splitRoot, targets, SHARED_CONFIG_DIR, CONFIG_DIRS } =
  require("../out/core/placement.js");
const { decode, ledger, ledgerPath, LEDGER_DIR } = require("../out/core/ledger.js");
const { add, find, isRemovable, MAX_BROWSER_COLLECTION_ENTRIES } =
  require("../out/core/collection.js");
const { treeHash } = require("../out/core/hash.js");

// --- 検知 ---------------------------------------------------------------

test("パス名から Skill と Subagent を当てる", () => {
  assert.equal(kindOf(["skills", "pdf"]), "skill");
  assert.equal(kindOf(["agents", "reviewer.md"]), "subagent");
  assert.equal(kindOf(["subagents", "reviewer.md"]), "subagent");
});

test("Plugin と MCP は候補にしない", () => {
  assert.equal(kindOf(["plugins", "foo"]), null);
  assert.equal(kindOf([".claude-plugin", "plugin.json"]), null);
  assert.equal(kindOf(["src", "index.ts"]), null);
  // plugins を含むなら skills があっても拾わない
  assert.equal(kindOf(["plugins", "foo", "skills", "bar"]), null);
});

test("Skill のディレクトリ URL は SKILL.md を根拠にする", () => {
  const found = lead("https://github.com/owner/repo/tree/main/skills/pdf");
  assert.equal(found.kind, "skill");
  assert.equal(found.name, "pdf");
  assert.deepEqual(found.proofs, ["skills/pdf/SKILL.md"]);
  assert.deepEqual(proofUrls(found), [
    "https://raw.githubusercontent.com/owner/repo/main/skills/pdf/SKILL.md",
  ]);
});

test("SKILL.md を直接指されたら親を採る", () => {
  const found = lead("https://github.com/owner/repo/blob/main/skills/pdf/SKILL.md");
  assert.equal(found.name, "pdf");
  assert.deepEqual(found.proofs, ["skills/pdf/SKILL.md"]);
});

test("Subagent はファイル指定だけを受ける", () => {
  const file = lead("https://github.com/owner/repo/blob/main/agents/reviewer.md");
  assert.equal(file.kind, "subagent");
  assert.equal(file.name, "reviewer");
  assert.deepEqual(file.proofs, ["agents/reviewer.md"]);
  // ディレクトリだと中のファイル名が分からず確認できない
  assert.equal(lead("https://github.com/owner/repo/tree/main/agents"), null);
});

test("カタログはスキル名があるときだけ候補にする", () => {
  const found = lead("https://skills.sh/owner/repo/grilling");
  assert.equal(found.kind, "skill");
  assert.equal(found.name, "grilling");
  assert.deepEqual(found.proofs, []);            // 実在確認は不要
  assert.equal(lead("https://skills.sh/owner/repo"), null);
});

test("対応外の URL とリポジトリのトップは拾わない", () => {
  assert.equal(lead("https://example.com/skills/pdf"), null);
  assert.equal(lead("https://github.com/owner/repo"), null);
  assert.equal(lead("https://github.com/owner/repo/issues/1"), null);
  assert.equal(lead(""), null);
});

// --- 配置 ---------------------------------------------------------------

test("Skill の導入先は Claude / Cursor / Codex", () => {
  assert.deepEqual(targets("skill"), ["claude", "cursor", "codex"]);
});

test("Subagent の導入先は Claude と Cursor だけ", () => {
  assert.deepEqual(targets("subagent"), ["claude", "cursor"]);
});

test("共有ストアがあれば Cursor と Codex は同じ場所に置く", () => {
  for (const agent of ["cursor", "codex"]) {
    assert.deepEqual(placement(agent, "skill", "pdf", true),
      { configDir: SHARED_CONFIG_DIR, sub: "skills", entry: "pdf", isDirectory: true });
  }
});

test("共有ストアが無ければ各エージェント直下へ退避する", () => {
  assert.equal(rootOf(placement("cursor", "skill", "pdf", false)), ".cursor/skills");
  assert.equal(rootOf(placement("codex", "skill", "pdf", false)), ".codex/skills");
});

test("Claude は共有ストアを読まないので常に自分の下へ置く", () => {
  // 共有ストアを許可済みでも Claude はそこを読まない。
  assert.equal(rootOf(placement("claude", "skill", "pdf", true)), ".claude/skills");
});

test("Subagent は .md ファイルとして置く", () => {
  assert.deepEqual(placement("claude", "subagent", "reviewer", true),
    { configDir: ".claude", sub: "agents", entry: "reviewer.md", isDirectory: false });
});

test("利用者に選ばせるのは設定ディレクトリだけ", () => {
  // `skills` と `agents` はそこから辿る。ピッカーはエージェントごとに 1 回で済む。
  assert.deepEqual([...CONFIG_DIRS], [".claude", ".cursor", ".codex", ".agents"]);
  for (const agent of ["claude", "cursor", "codex"]) {
    for (const kind of ["skill", "subagent"]) {
      const where = placement(agent, kind, "x", false);
      if (where === null) continue;
      assert.ok(CONFIG_DIRS.includes(where.configDir), `${agent} ${kind}`);
    }
  }
});

test("ルートは設定ディレクトリと置き場に割り戻せる", () => {
  const where = placement("claude", "skill", "pdf", false);
  assert.deepEqual(splitRoot(rootOf(where)), { configDir: ".claude", sub: "skills" });
  assert.deepEqual(splitRoot(".agents/skills"), { configDir: ".agents", sub: "skills" });
});

test("非対応の組み合わせには置き場を返さない", () => {
  assert.equal(placement("codex", "subagent", "reviewer", false), null);
  assert.equal(placement("gemini", "skill", "pdf", false), null);
});

// --- 台帳 ---------------------------------------------------------------

test("台帳は取得元と commit SHA だけを持つ", () => {
  const entry = ledger("pdf", "skill", { repo: "owner/repo", branch: "main", subdir: "skills/pdf" }, "abc123");
  assert.deepEqual(entry,
    { name: "pdf", kind: "skill", repo: "owner/repo", branch: "main", subdir: "skills/pdf", sha: "abc123" });
  assert.equal("pinned" in entry, false);
  assert.equal("disabled" in entry, false);
  assert.equal("treeHash" in entry, false);
});

test("未指定のキーは書き出さない", () => {
  assert.deepEqual(ledger("pdf", "skill", { repo: "owner/repo" }),
    { name: "pdf", kind: "skill", repo: "owner/repo" });
});

test("台帳の置き場はルート直下の隠しディレクトリ", () => {
  assert.equal(LEDGER_DIR, ".agent-tool");
  assert.equal(ledgerPath("pdf"), ".agent-tool/pdf.json");
});

test("往復しても同じ台帳になる", () => {
  const entry = ledger("pdf", "skill", { repo: "owner/repo", branch: "main" }, "abc");
  assert.deepEqual(decode(JSON.parse(JSON.stringify(entry))), entry);
});

test("壊れた台帳は読まない", () => {
  for (const broken of [null, [], "x", 1, {}, { name: "pdf" },
                        { name: "pdf", kind: "skill", repo: "no-slash" },
                        { name: "pdf", kind: "plugin", repo: "owner/repo" },
                        { name: "", kind: "skill", repo: "owner/repo" }]) {
    assert.equal(decode(broken), null, JSON.stringify(broken));
  }
});

// --- 収集一覧 -----------------------------------------------------------

const collected = (name, at) => ({
  name, kind: "skill", agent: "claude", root: ".claude/skills",
  repo: "owner/repo", treeHash: `hash-${name}`, installedAt: at,
});

test("同じ導入先の同名は 1 件に保つ", () => {
  const list = add([collected("pdf", 1)], { ...collected("pdf", 2), treeHash: "new" });
  assert.equal(list.length, 1);
  assert.equal(list[0].treeHash, "new");
});

test("上限を超えたら古い順に捨てる", () => {
  let list = [];
  for (let index = 0; index < MAX_BROWSER_COLLECTION_ENTRIES + 1; index++) {
    list = add(list, collected(`skill-${index}`, index));
  }
  assert.equal(list.length, MAX_BROWSER_COLLECTION_ENTRIES);
  assert.equal(list[0].name, "skill-1");                 // 最古が落ちた
  assert.equal(list[list.length - 1].name, `skill-${MAX_BROWSER_COLLECTION_ENTRIES}`);
});

test("実体ツリー hash が一致するときだけ削除を許す", () => {
  const list = [collected("pdf", 1)];
  const entry = find(list, { name: "pdf", kind: "skill", agent: "claude", root: ".claude/skills" });
  assert.equal(isRemovable(entry, "hash-pdf"), true);
  assert.equal(isRemovable(entry, "changed"), false);     // 手で書き換えられた
  assert.equal(isRemovable(undefined, "hash-pdf"), false); // 自分が入れたものではない
});

// --- ツリー hash --------------------------------------------------------

const bytes = text => new TextEncoder().encode(text);

test("走査順が違っても同じ hash になる", async () => {
  const a = [{ path: "SKILL.md", bytes: bytes("one") }, { path: "b/c.txt", bytes: bytes("two") }];
  assert.equal(await treeHash(a), await treeHash([...a].reverse()));
});

test("内容もパスも hash に効く", async () => {
  const base = [{ path: "SKILL.md", bytes: bytes("one") }];
  assert.notEqual(await treeHash(base), await treeHash([{ path: "SKILL.md", bytes: bytes("two") }]));
  assert.notEqual(await treeHash(base), await treeHash([{ path: "OTHER.md", bytes: bytes("one") }]));
});

test("長さを混ぜるので境界をずらしても衝突しない", async () => {
  const first = [{ path: "a", bytes: bytes("xy") }, { path: "b", bytes: bytes("z") }];
  const second = [{ path: "a", bytes: bytes("x") }, { path: "b", bytes: bytes("yz") }];
  assert.notEqual(await treeHash(first), await treeHash(second));
});

// --- カタログの実体を探す -----------------------------------------------

const { locateSkill } = require("../out/core/detect.js");
const file = (path, body = "") => ({ path, bytes: new TextEncoder().encode(body) });

test("ディレクトリ名が一致すればそれを採る", () => {
  assert.deepEqual(locateSkill([
    file("skills/pdf/SKILL.md", "---\nname: pdf\n---\n"),
    file("skills/other/SKILL.md", "---\nname: other\n---\n"),
  ], "pdf"), ["skills", "pdf"]);
});

test("ディレクトリ名が違えば frontmatter の name で探す", () => {
  // skills.sh は vercel-react-best-practices と出すが、実体は skills/react-best-practices。
  assert.deepEqual(locateSkill([
    file("skills/react-best-practices/SKILL.md", "---\nname: vercel-react-best-practices\n---\n"),
    file("skills/deploy/SKILL.md", "---\nname: deploy-to-vercel\n---\n"),
  ], "vercel-react-best-practices"), ["skills", "react-best-practices"]);
});

test("候補が複数あれば浅い方を採る", () => {
  assert.deepEqual(locateSkill([
    file("examples/nested/pdf/SKILL.md", "---\nname: pdf\n---\n"),
    file("skills/pdf/SKILL.md", "---\nname: pdf\n---\n"),
  ], "pdf"), ["skills", "pdf"]);
});

test("どちらでも当たらなければ null", () => {
  assert.equal(locateSkill([file("skills/other/SKILL.md", "---\nname: other\n---\n")], "pdf"), null);
  assert.equal(locateSkill([file("README.md", "x")], "pdf"), null);
  assert.equal(locateSkill([], "pdf"), null);
});

test("リポジトリ直下の SKILL.md は候補にしない", () => {
  // 親ディレクトリが無いと名前が決まらない。
  assert.equal(locateSkill([file("SKILL.md", "---\nname: pdf\n---\n")], "pdf"), null);
});

// --- カタログの予約パス -------------------------------------------------

const { catalog } = require("../out/core/github.js");

test("skills.sh の site は GitHub の取得元ではない", () => {
  // /site/<ドメイン>/<名前> は GitHub 以外が配っているもの。
  assert.equal(catalog("https://www.skills.sh/site/open.feishu.cn/lark-vc-agent"), null);
  assert.equal(lead("https://www.skills.sh/site/open.feishu.cn/lark-vc-agent"), null);
});

test("www つきのカタログも読む", () => {
  const found = lead("https://www.skills.sh/vercel-labs/agent-skills/vercel-react-best-practices");
  assert.equal(found.source.repo, "vercel-labs/agent-skills");
  assert.equal(found.name, "vercel-react-best-practices");
});
