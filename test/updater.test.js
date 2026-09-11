const { strict: assert } = require("node:assert");
const { mkdirSync, mkdtempSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const { API_RESPONSE_LIMIT, DIFF_TOTAL_LIMIT, diffFiles, readLimitedText } = require("../out/updater.js");

test("大きすぎる GitHub 応答は読み切らずに落とす", async () => {
  const body = {
    async *[Symbol.asyncIterator]() {
      yield new Uint8Array(API_RESPONSE_LIMIT);
      yield new Uint8Array(1);
    },
  };
  await assert.rejects(readLimitedText(body, API_RESPONSE_LIMIT), error => error.code === "FETCH_FAILED");
});

test("差分に載せる本文は合計で打ち切る", t => {
  const root = mkdtempSync(join(tmpdir(), "agent-tool-diff-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const current = join(root, "current");
  const candidate = join(root, "candidate");
  mkdirSync(current); mkdirSync(candidate);
  for (let i = 0; i < 9; i += 1) writeFileSync(join(candidate, `${i}.md`), "x".repeat(250 * 1024));
  const diff = diffFiles(current, candidate, "tool");
  const retained = diff.reduce((size, file) => size + Buffer.byteLength(file.before) + Buffer.byteLength(file.after), 0);
  assert.ok(retained <= DIFF_TOTAL_LIMIT);
  assert.equal(diff.at(-1).path, "[additional changes omitted]");
});
