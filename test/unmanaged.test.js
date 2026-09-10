// 他のツールが入れた実体の削除。registry に載っていないので lifecycle とは別経路。
const { strict: assert } = require("node:assert");
const { existsSync, symlinkSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { claudeSkills, skillStore } = require("../out/env.js");
const { removeUnmanaged } = require("../out/skillManager.js");
const { assertUserArtifact, userRoots } = require("../out/writeGuard.js");
const { fakeEnv, link, makeDir, writeFileIn } = require("./helpers.js");

const code = expected => error => error.code === expected;

/** 実体を共有ストアに置き、Claude 用のリンクを張る（他ツールが作る形）。 */
function foreignSkill(env, name) {
  const body = makeDir(join(skillStore(env), name));
  writeFileIn(join(body, "SKILL.md"), `---\nname: ${name}\n---\n`);
  const alias = link(body, join(claudeSkills(env), name));
  return { body, alias };
}

/**
 * registry に無くても、既知ルート直下にあるものは利用者の資産として消せる。
 * 一覧に出ているのに入れた経路が違うだけで消せない、では通らない。
 */
test("registry に無い実体とリンクをまとめて消す", () => {
  const env = fakeEnv();
  const { body, alias } = foreignSkill(env, "improve-codebase-architecture");
  const removed = removeUnmanaged("improve-codebase-architecture", "skill", env);
  assert.equal(removed.length, 2);
  assert.equal(existsSync(body), false);
  assert.equal(existsSync(alias), false);
});

test("どのルートにも無ければ NOT_FOUND", () => {
  const env = fakeEnv();
  assert.throws(() => removeUnmanaged("ghost", "skill", env), code("NOT_FOUND"));
});

/** 消してもエージェントの更新で戻るものには触らない。 */
test("同梱ルートの実体は消さない", () => {
  const env = fakeEnv();
  const bundled = makeDir(join(env.home, ".cursor/skills-cursor/canvas"));
  writeFileIn(join(bundled, "SKILL.md"), "---\nname: canvas\n---\n");
  assert.throws(() => removeUnmanaged("canvas", "skill", env), code("NOT_FOUND"));
  assert.ok(existsSync(bundled), "同梱スキルは残る");
});

test("既知ルートの一覧に同梱ルートを含めない", () => {
  const env = fakeEnv();
  const roots = userRoots("skill", env);
  assert.ok(roots.includes(join(env.home, ".agents/skills")));
  assert.ok(roots.includes(join(env.home, ".claude/skills")));
  assert.equal(roots.includes(join(env.home, ".cursor/skills-cursor")), false);
  assert.equal(roots.includes(join(env.home, ".codex/skills/.system")), false);
});

// --- assertUserArtifact ---

/** ルート直下だけを許す。深い位置のファイルまで消せると走査範囲の外に出る。 */
test("既知ルートの直下でなければ拒否する", () => {
  const env = fakeEnv();
  const nested = makeDir(join(skillStore(env), "pkg", "nested"));
  assert.throws(() => assertUserArtifact(nested, "skill", env), code("WRITE_GUARD_DENIED"));
});

test("保護対象の名前と隠しファイルは拒否する", () => {
  const env = fakeEnv();
  for (const leaf of ["auth.json", ".hidden"]) {
    assert.throws(() => assertUserArtifact(join(skillStore(env), leaf), "skill", env),
      code("WRITE_GUARD_DENIED"));
  }
});

test("Subagent は .md だけを対象にする", () => {
  const env = fakeEnv();
  const root = join(env.home, ".claude/agents");
  assertUserArtifact(join(root, "reviewer.md"), "subagent", env);
  assert.throws(() => assertUserArtifact(join(root, "reviewer"), "subagent", env),
    code("WRITE_GUARD_DENIED"));
});

test("MCP と Plugin はこの経路では扱わない", () => {
  const env = fakeEnv();
  for (const kind of ["mcp", "plugin"]) {
    assert.throws(() => assertUserArtifact(join(skillStore(env), "x"), kind, env),
      code("WRITE_GUARD_DENIED"));
  }
});

/** 既知ルートがホームの外へ張り替えられていたら、その先は消さない。 */
test("ホームの外へ出る親リンク経由は拒否する", () => {
  const env = fakeEnv();
  const outside = makeDir(join(env.home, "..", `outside-${process.pid}-${Date.now()}`));
  makeDir(env.home);
  symlinkSync(outside, join(env.home, ".agents"), "junction");
  assert.throws(() => assertUserArtifact(join(skillStore(env), "x"), "skill", env),
    code("WRITE_GUARD_DENIED"));
});
