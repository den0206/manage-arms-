// 実際に入っている Agent CLI との契約検査。既定では走らない（COMPAT_AGENT で有効化）。
// すべての子プロセスに隔離したホームと作業ディレクトリを与え、資格情報を引き継がせない。
const { strict: assert } = require("node:assert");
const { mkdtempSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const { displayName } = require("../out/core/agent.js");
const { cliName } = require("../out/ide/agent.js");
const { parseVersion } = require("../out/ide/detector.js");
const { run } = require("../out/ide/exec.js");
const { add, read, remove } = require("../out/ide/mcpScanner.js");
const { read: readPlugins } = require("../out/ide/pluginScanner.js");

const agent = process.env.COMPAT_AGENT;

test("導入済み CLI が MCP の往復と Plugin コマンドの契約を満たす", async t => {
  if (!agent) return t.skip("COMPAT_AGENT が未指定");
  const cli = cliName(agent);
  assert.ok(cli, `${agent} には CLI がありません`);

  const home = mkdtempSync(join(tmpdir(), "agent-compat-"));
  const env = { home, appSupport: join(home, "storage") };
  const path = process.env.PATH ?? "/usr/bin:/bin";
  const isolated = { HOME: home, PATH: path, TMPDIR: home, CI: "true", NO_COLOR: "1" };
  const runner = command => run(command, { path, cwd: home, envOverride: isolated });

  try {
    const version = await runner([cli, "--version"]);
    console.log(`Compatibility: ${displayName(agent)} ${version.trim()}`);
    assert.ok(parseVersion(version) !== null, version);

    const probe = {
      name: "agent-tool-compat-probe",
      transport: { type: "stdio", command: "/usr/bin/true", args: ["--probe", "quoted value"], env: { AGENT_TOOL_PROBE: "isolated" } },
      isProtected: false,
      enabled: true,
    };
    await add(probe, agent, env, runner);
    const registered = (await read(agent, env, runner)).find(item => item.name === probe.name);
    assert.deepEqual(registered.transport, probe.transport);
    await remove(probe.name, agent, env, runner);
    assert.equal((await read(agent, env, runner)).some(item => item.name === probe.name), false);

    const remote = {
      name: "agent-tool-http-probe",
      transport: {
        type: "http",
        url: "https://example.invalid/mcp",
        headers: agent === "codex" ? {} : { "X-Agent-Tool": "isolated" },
      },
      isProtected: false,
      enabled: true,
    };
    await add(remote, agent, env, runner);
    assert.deepEqual((await read(agent, env, runner)).find(item => item.name === remote.name).transport,
      remote.transport);
    await remove(remote.name, agent, env, runner);

    if (agent === "claude" || agent === "codex") {
      await runner([cli, "plugin", agent === "claude" ? "install" : "add", "--help"]);
      await runner([cli, "plugin", "remove", "--help"]);
      await readPlugins(agent, env, runner);
    }
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});
