const { strict: assert } = require("node:assert");
const { existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const agentTool = require("../out/agentTool.js");
const { hasUpdate, inventory } = require("../out/inventory.js");
const { addCommand, removeCommand, editCursor, validate } = require("../out/mcpScanner.js");
const { parseAll } = require("../out/mcpServer.js");
const { fakeEnv, makeDir, writeFileIn } = require("./helpers.js");

const code = expected => error => error.code === expected;
const server = (name, definition) => parseAll({ mcpServers: { [name]: definition } })[0];

/** プロセス境界が無いので版ずれは起きない。互換判定は registry の schemaVersion だけ。 */
test("互換判定は registry の schemaVersion が持つ", () => {
  const { SCHEMA_VERSION, decode } = require("../out/registry.js");
  assert.equal(SCHEMA_VERSION, "1");
  assert.throws(() => decode({ schemaVersion: "2" }), code("SCHEMA_UNSUPPORTED"));
});

test("公開 GitHub 以外の URL は受け付けない", async () => {
  await assert.rejects(agentTool.preview({ url: "https://example.com/x" }), code("NOT_FOUND"));
});

test("一覧は storagePath だけで組み立てられる", async () => {
  const env = fakeEnv();
  const { items, issues } = await inventory({ env, projectPath: null });
  assert.ok(Array.isArray(items));
  assert.ok(Array.isArray(issues));
});

// --- MCP の CLI 引数 ---

/** 名前は可変長の -e / -H より前に置く。後ろだと直前のフラグの値として食われる。 */
test("claude の add は名前を可変長フラグより前に置く", () => {
  const argv = addCommand(server("db", { command: "npx", args: ["-y", "pg"], env: { URL: "x" } }), "claude");
  assert.deepEqual(argv, ["claude", "mcp", "add", "-s", "user", "db", "-e", "URL=x", "--", "npx", "-y", "pg"]);
});

/** gemini は `--` を受けないので位置引数で渡す。 */
test("gemini の add は -- を挟まない", () => {
  const argv = addCommand(server("db", { command: "npx", args: ["pg"] }), "gemini");
  assert.deepEqual(argv, ["gemini", "mcp", "add", "-s", "user", "db", "npx", "pg"]);
});

test("codex の add は --env と -- を使う", () => {
  const argv = addCommand(server("db", { command: "node", args: ["s.js"], env: { A: "1" } }), "codex");
  assert.deepEqual(argv, ["codex", "mcp", "add", "--env", "A=1", "db", "--", "node", "s.js"]);
});

test("HTTP のヘッダは -H で渡す", () => {
  const argv = addCommand(server("api", { url: "https://x/mcp", headers: { Authorization: "Bearer t" } }), "claude");
  assert.deepEqual(argv, ["claude", "mcp", "add", "-s", "user", "api",
    "-t", "http", "https://x/mcp", "-H", "Authorization: Bearer t"]);
});

test("Cursor は CLI を持たないので argv を返さない", () => {
  assert.equal(addCommand(server("a", { command: "x" }), "cursor"), null);
  assert.equal(removeCommand("a", "cursor", "user"), null);
});

/** ユーザー全体に入れるには -s user が要る（claude / gemini の既定は local）。 */
test("remove は渡されたスコープをそのまま -s に載せる", () => {
  assert.deepEqual(removeCommand("a", "claude", "user"), ["claude", "mcp", "remove", "a", "-s", "user"]);
  // プロジェクトのサーバーを user のつもりで消さない。
  assert.deepEqual(removeCommand("a", "claude", "local"), ["claude", "mcp", "remove", "a", "-s", "local"]);
  // codex はスコープの概念を持たない。
  assert.deepEqual(removeCommand("a", "codex", "project"), ["codex", "mcp", "remove", "a"]);
});

// --- 入力の検査 ---

test("名前と接続先の形を確かめる", () => {
  assert.throws(() => validate(server("bad name", { command: "x" }), "claude"), code("INVALID_NAME"));
  assert.throws(() => validate(server("a", { url: "ftp://x" }), "claude"), code("OPERATION_FAILED"));
  assert.throws(() => validate({ ...server("a", { command: "x" }), isProtected: true }, "claude"),
    code("WRITE_GUARD_DENIED"));
  validate(server("ok-name.1", { command: "npx", args: [] }), "claude");
});

/** Codex CLI はヘッダを登録できない。黙って落とさず理由を出す。 */
test("Codex に HTTP ヘッダは渡せない", () => {
  assert.throws(() => validate(server("a", { url: "https://x", headers: { A: "b" } }), "codex"),
    code("OPERATION_FAILED"));
});

// --- Cursor の mcp.json 直接編集 ---

test("mcpServers 以外のキーを触らない", () => {
  const env = fakeEnv();
  const path = writeFileIn(join(env.home, ".cursor", "mcp.json"),
    '{"other":{"keep":true},"mcpServers":{"old":{"command":"x"}}}');
  editCursor(env, servers => { servers.added = { command: "y" }; });
  const written = JSON.parse(readFileSync(path, "utf8"));
  assert.deepEqual(written.other, { keep: true });
  assert.deepEqual(Object.keys(written.mcpServers).sort(), ["added", "old"]);
});

/** 書き戻すとコメントは復元されない。利用者が意図的に残した設定を消さない。 */
test("コメント入りの mcp.json は書き換えない", () => {
  const env = fakeEnv();
  const path = writeFileIn(join(env.home, ".cursor", "mcp.json"),
    '{\n // figma は一時停止中\n "mcpServers": {}\n}');
  assert.throws(() => editCursor(env, servers => { servers.a = { command: "x" }; }), code("OPERATION_FAILED"));
  assert.ok(readFileSync(path, "utf8").includes("figma は一時停止中"));
});

test("設定が無ければ新しく作る", () => {
  const env = fakeEnv();
  makeDir(env.home);
  editCursor(env, servers => { servers.a = { command: "x" }; });
  const written = JSON.parse(readFileSync(join(env.home, ".cursor", "mcp.json"), "utf8"));
  assert.deepEqual(written.mcpServers.a, { command: "x" });
});

test("書き込みは一時ファイルを残さない", () => {
  const env = fakeEnv();
  makeDir(env.home);
  editCursor(env, servers => { servers.a = { command: "x" }; });
  assert.equal(existsSync(join(env.home, ".cursor", "mcp.json.tmp")), false);
});

/**
 * 取り違えの回帰検査。`layout` は user スコープの置き場しか組まないので、
 * project スコープを通すと同名の user 実体を消してしまう（ゴミ箱を経由しない）。
 */
test("project スコープの削除は user スコープの実体に触れない", async () => {
  const env = fakeEnv();
  const store = makeDir(join(env.home, ".agents", "skills", "shared"));
  writeFileIn(join(store, "SKILL.md"), "---\nname: shared\n---\n");
  writeFileIn(join(env.appSupport, "registry.json"),
    JSON.stringify({ schemaVersion: "1", resources: [{ name: "shared", kind: "skill" }] }));

  const selector = { name: "shared", kind: "skill", scope: "project", agent: "claude" };
  await assert.rejects(agentTool.remove({ storagePath: env.appSupport, selector }),
    code("OPERATION_FAILED"));
  await assert.rejects(agentTool.toggle({ storagePath: env.appSupport, selector }),
    code("OPERATION_FAILED"));
  assert.ok(existsSync(join(store, "SKILL.md")));
});

test("MCP と Plugin は実体管理の対象にしない", () => {
  for (const kind of ["mcp", "plugin"]) {
    assert.equal(agentTool.isManageable({ name: "x", kind, scope: "user", agent: "claude" }), false);
  }
  assert.ok(agentTool.isManageable({ name: "x", kind: "skill", scope: "user", agent: "claude" }));
});

/** `-s` を既定値で埋めると、プロジェクトのサーバーを消したつもりで user が消える。 */
test("MCP の削除コマンドは渡されたスコープを載せる", () => {
  assert.deepEqual(removeCommand("probe", "claude", "project"),
    ["claude", "mcp", "remove", "probe", "-s", "project"]);
  assert.deepEqual(removeCommand("probe", "claude", "local"),
    ["claude", "mcp", "remove", "probe", "-s", "local"]);
  assert.deepEqual(removeCommand("probe", "claude", "user"),
    ["claude", "mcp", "remove", "probe", "-s", "user"]);
});

test("Plugin は marketplace を登録してから追加し、削除時は登録 scope を使う", () => {
  assert.deepEqual(agentTool.pluginAddCommands("claude", "tool@market", "https://github.com/acme/plugins"), [
    ["claude", "plugin", "marketplace", "add", "https://github.com/acme/plugins"],
    ["claude", "plugin", "install", "tool@market", "-s", "user"],
  ]);
  assert.deepEqual(agentTool.pluginAddCommands("codex", "tool@market"),
    [["codex", "plugin", "add", "tool@market"]]);
  assert.deepEqual(agentTool.pluginRemoveCommand("claude", "tool@market", "local"),
    ["claude", "plugin", "remove", "tool@market", "-s", "local"]);
});

test("GitHub サブディレクトリの Plugin は Marketplace のルートを登録する", () => {
  assert.deepEqual(agentTool.pluginAddCommands("claude", "context7",
    "https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/context7"), [
    ["claude", "plugin", "marketplace", "add", "https://github.com/anthropics/claude-plugins-official"],
    ["claude", "plugin", "install", "context7@claude-plugins-official", "-s", "user"],
  ]);
});

/** Windows は `.cmd` のために shell 実行が要るが、Node は引数をクォートしない。 */
test("Windows で shell 構文を含むコマンドは実行しない", () => {
  const { hasShellSyntax } = require("../out/exec.js");
  assert.ok(hasShellSyntax(["npx", "-y", "pkg & calc.exe"]));
  assert.ok(hasShellSyntax(["npx", "a | b"]));
  assert.ok(hasShellSyntax(["npx", "%PATH%"]));
  assert.equal(hasShellSyntax(["claude", "mcp", "add", "-s", "user", "probe", "--", "npx", "-y", "pkg"]), false);
  assert.equal(hasShellSyntax(["C:\\Program Files\\claude\\claude.cmd", "--version"]), false);
});

// --- 追加先スコープ ---

test("project スコープはワークスペースが分かるときだけ管理できる", () => {
  const selector = extra => ({ name: "pdf", kind: "skill", scope: "project", agent: "claude", ...extra });
  assert.equal(agentTool.isManageable(selector()), false);
  assert.equal(agentTool.isManageable(selector({ projectPath: "/w" })), true);
  // 退避先を持たないので、有効化・無効化は出さない。
  assert.equal(agentTool.isTogglable(selector({ projectPath: "/w" })), false);
  // サブディレクトリのスキルは `.claude/skills` 直下ではない。
  assert.equal(agentTool.isManageable(selector({ projectPath: "/w", name: "apps/web:deploy" })), false);
  assert.equal(agentTool.isTogglable({ name: "pdf", kind: "skill", scope: "user", agent: "claude" }), true);
});

/** 黙って user に入れると、プロジェクトに入れたつもりのものが全プロジェクトへ漏れる。 */
test("ワークスペースが無いまま project を指定したら user へ落とさない", async () => {
  const env = fakeEnv();
  await assert.rejects(agentTool.add({
    storagePath: env.appSupport, url: "https://github.com/o/r", kind: "skill", scope: "project",
  }), code("OPERATION_FAILED"));
});

// --- 更新確認 ---

/** ここが走らないと registry.repos が空のままで、更新の導線が一生出ない。 */
test("更新確認は最新 SHA を registry に記録する", async () => {
  const env = fakeEnv();
  const { empty, save, read } = require("../out/registry.js");
  const registry = empty();
  registry.resources = [
    { name: "pdf", kind: "skill", repo: "o/r", sha: "old", pinned: false, disabled: false },
    { name: "fixed", kind: "skill", repo: "o/pinned", sha: "old", pinned: true, disabled: false },
    { name: "local", kind: "skill", pinned: false, disabled: false },
  ];
  await save(env, registry);

  const asked = [];
  const http = async url => {
    asked.push(url);
    return url.includes("/o/r/") ? { status: 200, body: JSON.stringify({ sha: "new" }), headers: {} }
      : { status: 404, body: "", headers: {} };
  };
  const result = await agentTool.checkUpdates({ storagePath: env.appSupport, http });

  assert.equal(result.checked, 1);
  assert.deepEqual(result.issues, []);
  // 固定中と取得元の無いものは問い合わせない。
  assert.equal(asked.length, 1);
  const saved = read(env);
  assert.equal(saved.repos["o/r#main"].latestSha, "new");
  assert.ok(saved.repos["o/r#main"].checkedAt);
  assert.equal(hasUpdate(saved.resources[0], saved), true);
});

test("確認できなかった取得元は理由を返し、他の記録は残す", async () => {
  const env = fakeEnv();
  const { empty, save, read } = require("../out/registry.js");
  const registry = empty();
  registry.resources = [
    { name: "ok", kind: "skill", repo: "o/ok", sha: "a", pinned: false, disabled: false },
    { name: "gone", kind: "skill", repo: "o/gone", sha: "a", pinned: false, disabled: false },
  ];
  await save(env, registry);

  const result = await agentTool.checkUpdates({
    storagePath: env.appSupport,
    http: async url => url.includes("/o/ok/")
      ? { status: 200, body: JSON.stringify({ sha: "b" }), headers: {} }
      : { status: 404, body: "", headers: {} },
  });
  assert.equal(result.checked, 1);
  assert.equal(result.issues.length, 1);
  assert.match(result.issues[0], /o\/gone#main/);
  assert.equal(read(env).repos["o/ok#main"].latestSha, "b");
});
