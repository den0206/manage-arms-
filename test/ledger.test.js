const { strict: assert } = require("node:assert");
const { chmodSync, existsSync, readdirSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { absorb, key, prune, scan } = require("../out/ide/ledger.js");
const { LEDGER_DIR } = require("../out/core/ledger.js");
const { empty, upsert } = require("../out/ide/registry.js");
const { assertLedger, removeLedger } = require("../out/ide/writeGuard.js");
const { fakeEnv, makeDir, writeFileIn } = require("./helpers.js");

/** ブラウザ拡張が置いた状態を偽のホームに作る。 */
function fixture() {
  const env = fakeEnv();
  makeDir(env.home);
  const root = join(env.home, ".claude", "skills");
  return {
    env,
    root,
    /** 実体と台帳をまとめて置く。 */
    skill(name, ledger = { name, kind: "skill", repo: "owner/repo", sha: "abc" }) {
      writeFileIn(join(root, name, "SKILL.md"), `---\nname: ${name}\ndescription: d\n---\n`);
      writeFileIn(join(root, LEDGER_DIR, `${name}.json`), JSON.stringify(ledger));
      return join(root, LEDGER_DIR, `${name}.json`);
    },
    subagent(name) {
      writeFileIn(join(env.home, ".claude", "agents", `${name}.md`), `---\nname: ${name}\n---\n`);
      return writeFileIn(
        join(env.home, ".claude", "agents", LEDGER_DIR, `${name}.json`),
        JSON.stringify({ name, kind: "subagent", repo: "owner/repo" }));
    },
    /** 台帳だけを置く（実体が無い状態）。 */
    orphan(name) {
      return writeFileIn(join(root, LEDGER_DIR, `${name}.json`),
        JSON.stringify({ name, kind: "skill", repo: "owner/repo" }));
    },
  };
}

// --- 走査 ---------------------------------------------------------------

test("走査ルート直下の台帳を拾う", () => {
  const f = fixture();
  f.skill("pdf");
  f.subagent("reviewer");
  const found = scan(f.env);
  assert.deepEqual(found.map(item => item.ledger.name).sort(), ["pdf", "reviewer"]);
  assert.deepEqual(found.map(item => item.ledger.kind).sort(), ["skill", "subagent"]);
});

test("台帳が無いルートは黙って飛ばす", () => {
  assert.deepEqual(scan(fixture().env), []);
});

test("壊れた台帳は拾わない", () => {
  const f = fixture();
  writeFileIn(join(f.root, LEDGER_DIR, "broken.json"), "{ not json");
  writeFileIn(join(f.root, LEDGER_DIR, "empty.json"), "{}");
  writeFileIn(join(f.root, LEDGER_DIR, "plugin.json"),
    JSON.stringify({ name: "plugin", kind: "plugin", repo: "owner/repo" }));
  assert.deepEqual(scan(f.env), []);
});

test("ファイル名と中の name がずれた台帳は信用しない", () => {
  const f = fixture();
  writeFileIn(join(f.root, "pdf", "SKILL.md"), "---\nname: pdf\n---\n");
  writeFileIn(join(f.root, LEDGER_DIR, "pdf.json"),
    JSON.stringify({ name: "other", kind: "skill", repo: "owner/repo" }));
  assert.deepEqual(scan(f.env), []);
});

test("json 以外は読まない", () => {
  const f = fixture();
  writeFileIn(join(f.root, LEDGER_DIR, "notes.txt"), "x");
  assert.deepEqual(scan(f.env), []);
});

// --- 取り込み -----------------------------------------------------------

test("取り込むと registry に載り、台帳は消える", () => {
  const f = fixture();
  const file = f.skill("pdf");
  const registry = empty();

  absorb(f.env, registry, scan(f.env));
  assert.deepEqual(registry.resources, [{
    name: "pdf", kind: "skill", repo: "owner/repo", sha: "abc",
    pinned: false, disabled: false,
  }]);
  assert.equal(existsSync(file), false);
  // 実体には触れない
  assert.equal(existsSync(join(f.root, "pdf", "SKILL.md")), true);
  // .agent-tool ごとは消さない
  assert.equal(existsSync(join(f.root, LEDGER_DIR)), true);
});

test("取得元の任意キーは持っていた分だけ移す", () => {
  const f = fixture();
  f.skill("pdf", { name: "pdf", kind: "skill", repo: "owner/repo" });
  const registry = empty();
  absorb(f.env, registry, scan(f.env));
  assert.deepEqual(Object.keys(registry.resources[0]).sort(),
    ["disabled", "kind", "name", "pinned", "repo"]);
});

test("同じ名前を二度取り込んでも 1 件のまま", () => {
  const f = fixture();
  const registry = empty();
  f.skill("pdf");
  absorb(f.env, registry, scan(f.env));
  f.skill("pdf", { name: "pdf", kind: "skill", repo: "owner/repo", sha: "def" });
  absorb(f.env, registry, scan(f.env));
  assert.equal(registry.resources.length, 1);
  assert.equal(registry.resources[0].sha, "def");
});

// --- WriteGuard ---------------------------------------------------------

test("実体が無い台帳は消さない", () => {
  const f = fixture();
  const file = f.orphan("ghost");
  assert.throws(() => removeLedger(file, f.root, f.env), error => error.code === "NOT_FOUND");
  assert.equal(existsSync(file), true);
});

test("台帳以外は台帳の経路では消せない", () => {
  const f = fixture();
  f.skill("pdf");
  // 実体そのもの
  assert.throws(() => assertLedger(join(f.root, "pdf"), f.root, f.env),
    error => error.code === "WRITE_GUARD_DENIED");
  // .agent-tool の外にある json
  assert.throws(() => assertLedger(join(f.root, "pdf.json"), f.root, f.env),
    error => error.code === "WRITE_GUARD_DENIED");
  // ルート違い
  assert.throws(() => assertLedger(join(f.root, LEDGER_DIR, "pdf.json"),
    join(f.env.home, ".cursor", "skills"), f.env),
    error => error.code === "WRITE_GUARD_DENIED");
});

test("パスに使えない名前の台帳は消さない", () => {
  const f = fixture();
  writeFileIn(join(f.root, "x", "SKILL.md"), "---\nname: x\n---\n");
  const file = writeFileIn(join(f.root, LEDGER_DIR, ".hidden.json"), "{}");
  assert.throws(() => assertLedger(file, f.root, f.env),
    error => error.code === "WRITE_GUARD_DENIED");
  assert.equal(readdirSync(join(f.root, LEDGER_DIR)).length, 1);
});

// --- 実体を失った entry -------------------------------------------------

const managed = (name, project) => ({
  name, kind: "skill", repo: "owner/repo", pinned: false, disabled: false,
  ...(project === undefined ? {} : { project }),
});

test("走査したルートで実体が無い entry を落とす", () => {
  const registry = empty();
  upsert(registry, managed("kept"));
  upsert(registry, managed("gone"));
  prune(registry, {
    seen: new Set([key("kept", "skill")]),
    scannedUser: true, scannedProject: null,
  });
  assert.deepEqual(registry.resources.map(item => item.name), ["kept"]);
});

test("走査していない user スコープは落とさない", () => {
  const registry = empty();
  upsert(registry, managed("gone"));
  prune(registry, { seen: new Set(), scannedUser: false, scannedProject: null });
  assert.deepEqual(registry.resources.map(item => item.name), ["gone"]);
});

test("開いていないプロジェクトの entry を巻き込まない", () => {
  const registry = empty();
  upsert(registry, managed("here", "/work/a"));
  upsert(registry, managed("elsewhere", "/work/b"));
  prune(registry, { seen: new Set(), scannedUser: false, scannedProject: "/work/a" });
  assert.deepEqual(registry.resources.map(item => item.name), ["elsewhere"]);
});

test("同じ名前でも user と project を混同しない", () => {
  const registry = empty();
  upsert(registry, managed("pdf"));
  upsert(registry, managed("pdf", "/work/a"));
  prune(registry, {
    seen: new Set([key("pdf", "skill", "/work/a")]),
    scannedUser: true, scannedProject: "/work/a",
  });
  assert.deepEqual(registry.resources.map(item => item.project), ["/work/a"]);
});

// --- inventory との結線 -------------------------------------------------

const { inventory } = require("../out/ide/inventory.js");
const { load } = require("../out/ide/registry.js");

test("writable なら一覧を組むついでに取り込む", async () => {
  const f = fixture();
  const file = f.skill("pdf");
  const { items } = await inventory({
    env: f.env, projectPath: null, run: async () => "", writable: true,
  });
  const pdf = items.find(item => item.name === "pdf");
  assert.equal(pdf.origin, "managed");         // 取り込んだ結果が同じ走査に出る
  assert.equal(pdf.repoUrl, "owner/repo");
  assert.equal(existsSync(file), false);
  assert.equal(load(f.env).resources.length, 1);
});

test("writable でなければ registry に触らない", async () => {
  const f = fixture();
  const file = f.skill("pdf");
  const { items } = await inventory({ env: f.env, projectPath: null, run: async () => "" });
  assert.equal(items.find(item => item.name === "pdf").origin, "user");
  assert.equal(existsSync(file), true);         // 台帳は残る
  assert.deepEqual(load(f.env).resources, []);
});

test("実体を手で消したあとの entry は次の走査で落ちる", async () => {
  const f = fixture();
  f.skill("pdf");
  await inventory({ env: f.env, projectPath: null, run: async () => "", writable: true });
  assert.equal(load(f.env).resources.length, 1);

  require("node:fs").rmSync(join(f.root, "pdf"), { recursive: true, force: true });
  await inventory({ env: f.env, projectPath: null, run: async () => "", writable: true });
  assert.deepEqual(load(f.env).resources, []);
});

test("実体の無い台帳は取り込まない", () => {
  // 書き込みが途中で失敗すると台帳だけが残る。取り込むと、存在しないものの entry を
  // 作っては prune が消す往復が走査のたびに起きる。
  const f = fixture();
  f.orphan("ghost");
  f.skill("pdf");
  assert.deepEqual(scan(f.env).map(item => item.ledger.name), ["pdf"]);
});

test("読めないルートがあるときは entry を落とさない", async () => {
  // 権限・退避されたクラウド同期・切れたネットワークホームでは走査が空になる。
  // これを「消えた」と扱うと、実体が残っているのに pinned / disabled / 取得元を失う。
  const f = fixture();
  f.skill("pdf");
  await inventory({ env: f.env, projectPath: null, run: async () => "", writable: true });
  assert.equal(load(f.env).resources.length, 1);

  chmodSync(f.root, 0o000);
  try {
    const { issues } = await inventory({
      env: f.env, projectPath: null, run: async () => "", writable: true,
    });
    assert.equal(load(f.env).resources.length, 1);          // 残っている
    assert.ok(issues.some(issue => issue.includes(f.root))); // 黙って諦めない
  } finally {
    chmodSync(f.root, 0o755);
  }
});

test("実体の無い台帳があっても registry は安定する", async () => {
  const f = fixture();
  f.orphan("ghost");
  for (let round = 0; round < 2; round++) {
    await inventory({ env: f.env, projectPath: null, run: async () => "", writable: true });
    assert.deepEqual(load(f.env).resources, []);
  }
  assert.equal(existsSync(join(f.root, LEDGER_DIR, "ghost.json")), true);  // 消しはしない
});
