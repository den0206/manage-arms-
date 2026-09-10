const { strict: assert } = require("node:assert");
const { join } = require("node:path");
const { test } = require("node:test");
const { parseVersion, resolvePath, which } = require("../out/detector.js");
const {
  agentOfCommand, mcpStatus, owner, parsePs, parseWindows, running, signatures, stripVersion,
} = require("../out/processScanner.js");
const { classify, commandWords, mcpServers, parseCommand } = require("../out/pasteInput.js");
const { parseUrl, skillHint } = require("../out/github.js");
const { migrate } = require("../out/migration.js");
const { parseAll } = require("../out/mcpServer.js");
const { fakeEnv, makeDir, writeFileIn } = require("./helpers.js");

const code = expected => error => error.code === expected;
const server = (name, definition) => parseAll({ mcpServers: { [name]: definition } })[0];

// --- プロセス一覧 ---

test("ps の 4 列を読み、ヘッダ行を落とす", () => {
  const rows = parsePs([
    "  PID  PPID     ELAPSED COMMAND",
    "87139 87070       18:58 Cursor Helper: mcp-process",
    "  501     1 3-04:05:06 /usr/bin/node /path/server.js --port 1",
  ].join("\n"));
  assert.equal(rows.length, 2);
  assert.deepEqual(rows[0], { pid: 87139, ppid: 87070, elapsed: "18:58", command: "Cursor Helper: mcp-process" });
  assert.equal(rows[1].command, "/usr/bin/node /path/server.js --port 1");
});

test("Windows の CIM JSON を同じ 4 列に畳む", () => {
  const rows = parseWindows(JSON.stringify([
    { ProcessId: 10, ParentProcessId: 4, CreationDate: "2026-09-10", CommandLine: "node server.js" },
    { ProcessId: 11, ParentProcessId: 4, CommandLine: null },   // コマンド行が無い行は落とす
  ]));
  assert.deepEqual(rows, [{ pid: 10, ppid: 4, elapsed: "2026-09-10", command: "node server.js" }]);
});

test("単一オブジェクトで返る CIM JSON も読む", () => {
  const rows = parseWindows(JSON.stringify({ ProcessId: 1, ParentProcessId: 0, CommandLine: "x" }));
  assert.equal(rows.length, 1);
});

/** `npx` や `-y` のような共通語で照合すると無関係なプロセスに当たる。 */
test("照合に使う語から共通語と短い語を落とす", () => {
  const tokens = signatures(server("chrome", { command: "npx", args: ["-y", "chrome-devtools-mcp@latest"] }));
  assert.ok(tokens.includes("chrome-devtools-mcp"));
  assert.ok(!tokens.includes("npx"));
  assert.ok(!tokens.includes("-y"));
});

test("スコープ付きパッケージの先頭 @ は落とさない", () => {
  assert.equal(stripVersion("@scope/pkg@1.2.3"), "@scope/pkg");
  assert.equal(stripVersion("pkg@latest"), "pkg");
  assert.equal(stripVersion("plain"), "plain");
});

/** 名前一致ではなく、登録済みの定義とコマンド行を突き合わせる。 */
test("登録済みサーバーが動いているかをコマンド行で判定する", () => {
  const rows = parsePs([
    "  100     1    01:00 /Applications/Cursor.app/Contents/MacOS/Cursor",
    "  200   100    00:30 Cursor Helper: mcp-process",
    "  300   200    00:29 npm exec chrome-devtools-mcp",
    "  400   300    00:29 node /path/chrome-devtools-mcp/index.js",
  ].join("\n"));
  const live = running([server("chrome", { command: "npx", args: ["-y", "chrome-devtools-mcp@latest"] })], rows);
  const found = live.get("chrome");
  // 数珠つなぎのうち、親を持たないものが起点。
  assert.equal(found.pid, 300);
  assert.equal(found.elapsed, "00:29");
  assert.equal(found.owner, "cursor");
});

test("動いていないサーバーは返さない", () => {
  const rows = parsePs("  100     1    01:00 /usr/bin/zsh");
  assert.equal(running([server("figma", { command: "npx", args: ["figma-mcp"] })], rows).size, 0);
});

test("無効なサーバーは照合しない", () => {
  const rows = parsePs("  100     1    01:00 node figma-mcp/index.js");
  const disabled = { ...server("figma", { command: "npx", args: ["figma-mcp"] }), enabled: false };
  assert.equal(running([disabled], rows).size, 0);
});

/** Codex は Cursor の拡張の中に入っていることがある。実行ファイル名を先に見る。 */
test("実行ファイル名をパスより優先して所属を決める", () => {
  assert.equal(agentOfCommand("/Users/x/.cursor/extensions/openai.chatgpt/bin/codex mcp list"), "codex");
  assert.equal(agentOfCommand("/Applications/Cursor.app/Contents/MacOS/Cursor"), "cursor");
  assert.equal(agentOfCommand("/usr/bin/node index.js"), null);
});

test("親を辿る途中で循環しても止まる", () => {
  const rows = [
    { pid: 1, ppid: 2, elapsed: "", command: "a" },
    { pid: 2, ppid: 1, elapsed: "", command: "b" },
  ];
  assert.equal(owner(rows[0], rows), null);
});

test("MCP ステータスは agent:name のキーで返す", async () => {
  const run = async () => "  300     1    00:29 npm exec figma-mcp";
  const status = await mcpStatus({ cursor: [server("figma", { command: "npx", args: ["figma-mcp"] })] }, run);
  assert.deepEqual(status, { "cursor:figma": true });
});

// --- PATH 検知 ---

test("バージョン表記の揺れを吸収する", () => {
  assert.equal(parseVersion("2.1.236 (Claude Code)"), "2.1.236");
  assert.equal(parseVersion("codex-cli 0.153.2"), "0.153.2");
  assert.equal(parseVersion("v0.46.0\n"), "0.46.0");
  assert.equal(parseVersion("unknown"), null);
});

test("PATH を自分で辿って実行ファイルを探す", () => {
  const env = fakeEnv();
  const dir = makeDir(join(env.home, "bin"));
  writeFileIn(join(dir, "claude"), "#!/bin/sh\n");
  assert.equal(which("claude", dir), join(dir, "claude"));
  assert.equal(which("codex", dir), null);
});

/** ログインシェルが拾えても mise 等で漏れることがあるので、保険は常に足す。 */
test("既知のインストール先を必ず PATH に足す", async () => {
  const env = fakeEnv();
  const path = await resolvePath(env, async () => "/usr/bin");
  assert.ok(path.split(require("node:path").delimiter).includes(join(env.home, ".local", "bin")));
});

test("ログインシェルが失敗しても PATH を返す", async () => {
  const env = fakeEnv();
  const path = await resolvePath(env, async () => { throw new Error("no shell"); });
  assert.ok(path.length > 0);
});

// --- 貼り付け解析 ---

test("貼り付け内容を種別で振り分ける", () => {
  assert.equal(classify('{"mcpServers":{}}').kind, "mcpJson");
  assert.equal(classify("https://github.com/owner/repo").kind, "github");
  assert.equal(classify("github.com/owner/repo").kind, "github");
  assert.equal(classify("npx -y foo-mcp").kind, "command");
  assert.equal(classify("これは説明文です").kind, "unrecognized");
  assert.equal(classify("").kind, "unrecognized");
});

/** シェルの式は評価しないし、受け取りもしない。 */
test("シェルの式を含むコマンドは受け取らない", () => {
  assert.equal(parseCommand("npx foo; rm -rf /"), null);
  assert.equal(parseCommand("npx foo | tee x"), null);
  assert.equal(parseCommand("npx foo `id`"), null);
  assert.equal(parseCommand("npx foo $(id)"), null);
  assert.equal(parseCommand("ls -la"), null);              // 実行系でない先頭は受けない
});

test("引用符の中の空白は 1 語として読む", () => {
  assert.deepEqual(commandWords('npx -y "my server" --flag'), ["npx", "-y", "my server", "--flag"]);
  assert.equal(commandWords('npx "unterminated'), null);
});

test("blob URL はファイルではなく親ディレクトリを指す", () => {
  assert.deepEqual(parseUrl("https://github.com/o/r/blob/main/skills/pdf/SKILL.md"),
    { repo: "o/r", branch: "main", subdir: "skills/pdf", branchAmbiguous: true });
});

/** カタログの 3 番目はディレクトリ名であってパスではない。subdir にはできない。 */
test("カタログ URL は owner/repo だけを採る", () => {
  assert.deepEqual(parseUrl("https://skills.sh/owner/repo/grilling"), { repo: "owner/repo" });
  assert.equal(skillHint("https://skills.sh/owner/repo/grilling"), "grilling");
  assert.equal(parseUrl("https://skills.sh/agent/claude-code"), null);   // 予約パス
});

test("MCP の 3 形式を受ける", () => {
  assert.equal(mcpServers('{"command":"npx","args":["-y","x"]}', "a")[0].transport.command, "npx");
  assert.equal(mcpServers("https://example.com/mcp", "a")[0].transport.type, "http");
  assert.deepEqual(mcpServers('npx -y "my server"', "a")[0].transport.args, ["-y", "my server"]);
  assert.equal(mcpServers('{"mcpServers":{"b":{"command":"node"}}}', "a")[0].name, "b");
  assert.throws(() => mcpServers("何かの文章", "a"), code("OPERATION_FAILED"));
});

// --- 移行 ---

const legacy = () => join(require("node:os").homedir(), "Library/Application Support/ManageArms");

test("移行元が違えば受け付けない", async t => {
  if (process.platform !== "darwin") return t.skip("旧 ManageArms は macOS 専用");
  const env = fakeEnv();
  await assert.rejects(migrate(join(env.home, "elsewhere"), env), code("NOT_FOUND"));
});

test("移行先に既存データがあれば上書きしない", async t => {
  if (process.platform !== "darwin") return t.skip("旧 ManageArms は macOS 専用");
  const env = fakeEnv();
  const source = legacy();
  if (!require("node:fs").existsSync(join(source, "registry.json"))) {
    return t.skip("この環境に旧 ManageArms のデータが無い");
  }
  writeFileIn(join(env.appSupport, "registry.json"), "{}");
  await assert.rejects(migrate(source, env), code("MIGRATION_CONFLICT"));
});
