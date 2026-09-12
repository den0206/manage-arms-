import { readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";

const tests = readdirSync("test").filter(file => file.endsWith(".test.js")).sort().map(file => `test/${file}`);
const result = spawnSync(process.execPath, ["--test", ...tests], { stdio: "inherit" });

if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
