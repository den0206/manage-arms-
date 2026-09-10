const { mkdtempSync, mkdirSync, symlinkSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { dirname, join } = require("node:path");

/** 偽のホーム。実ユーザーのホームへは到達させない。 */
function fakeEnv() {
  const home = mkdtempSync(join(tmpdir(), "agent-tool-test-"));
  return { home, appSupport: join(home, "storage") };
}

const makeDir = path => (mkdirSync(path, { recursive: true }), path);

const writeFileIn = (path, body) => {
  makeDir(dirname(path));
  writeFileSync(path, body);
  return path;
};

/** Windows では symlink に昇格が要るので、ディレクトリは junction で張る。 */
const link = (target, path) => {
  makeDir(dirname(path));
  symlinkSync(target, path, process.platform === "win32" ? "junction" : undefined);
  return path;
};

module.exports = { fakeEnv, makeDir, writeFileIn, link };
