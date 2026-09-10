const { strict: assert } = require("node:assert");
const { mkdtemp, writeFile, chmod } = require("node:fs/promises");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const { runCli, setCliPath } = require("../out/cli.js");

test("runCli sends JSON and validates protocol", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-tool-cli-"));
  const file = join(dir, "fake-cli");
  await writeFile(file, "#!/bin/sh\ncat >/dev/null\nprintf '%s' '{\"ok\":true,\"protocolVersion\":\"1\"}'\n");
  await chmod(file, 0o755);
  setCliPath(file);
  assert.equal((await runCli("version", { value: 1 })).ok, true);
});

test("runCli rejects an incompatible protocol", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-tool-cli-"));
  const file = join(dir, "fake-cli");
  await writeFile(file, "#!/bin/sh\nprintf '%s' '{\"ok\":true,\"protocolVersion\":\"0\"}'\n");
  await chmod(file, 0o755);
  setCliPath(file);
  await assert.rejects(runCli("version"), /protocol mismatch/);
});

test("runCli surfaces the CLI error message on failure", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-tool-cli-"));
  const file = join(dir, "fake-cli");
  await writeFile(file, "#!/bin/sh\nprintf '%s' '{\"ok\":false,\"protocolVersion\":\"1\",\"error\":{\"code\":\"PLUGIN_ADD_FAILED\",\"message\":\"Marketplace was not found\"}}'\nexit 1\n");
  await chmod(file, 0o755);
  setCliPath(file);
  await assert.rejects(runCli("plugin-add"), /Marketplace was not found/);
});
