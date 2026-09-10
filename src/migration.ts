import { homedir } from "node:os";
import { join } from "node:path";
import { agentStore, disabledAgentStore, disabledStore, Env, registryFile } from "./env";
import { AgentToolError } from "./errors";
import { decode, save } from "./registry";
import * as guard from "./writeGuard";
import { readJsonc } from "./mcpScanner";

/**
 * 旧 ManageArms の保存領域。macOS 専用アプリなので、他の OS では検知そのものを行わない。
 */
export const legacyPath = (): string | null =>
  process.platform === "darwin"
    ? join(homedir(), "Library", "Application Support", "ManageArms")
    : null;

export const hasLegacyData = (): boolean => {
  const path = legacyPath();
  return path !== null && guard.exists(join(path, "registry.json"));
};

/**
 * 旧データを `globalStorageUri` へ移す。
 *
 * 移行先に既にデータがあれば上書きせず止める。旧ファイルには一切書き込まない —
 * 失敗しても元の環境はそのまま残り、次回起動で再試行できる。
 */
export async function migrate(source: string, env: Env):
  Promise<{ migratedEntries: number; skipped: number }> {
  const expected = legacyPath();
  if (expected === null || source !== expected || !guard.exists(join(source, "registry.json"))) {
    throw new AgentToolError("NOT_FOUND", "the ManageArms data directory was not found");
  }

  const stores = [
    ["agents", agentStore(env)],
    ["disabled-skills", disabledStore(env)],
    ["disabled-agents", disabledAgentStore(env)],
  ] as const;
  const targets = [registryFile(env), ...stores.map(([, target]) => target)];
  if (targets.some(guard.exists)) {
    throw new AgentToolError("MIGRATION_CONFLICT",
      "Agent Tool already holds data here; not overwriting it");
  }

  // browserDetection / menuBar / appearance は Mac App の設定。`decode` が落とす。
  const registry = decode(readJsonc(join(source, "registry.json")));

  // 検証してから移す。staging は OS の一時領域に置き、全経路で片付ける。
  const stage = guard.stagingDir("agent-tool-migration-");
  const moved: string[] = [];
  try {
    for (const [name, target] of stores) {
      const from = join(source, name);
      if (!guard.exists(from)) continue;
      guard.copy(from, join(stage, name));
      guard.prepare(target, join(target, ".."),
        guard.isInside(target, env.home) ? env.home : env.appSupport);
      guard.move(join(stage, name), target);
      moved.push(target);
    }
    await save(env, registry);
  } catch (error) {
    // 失敗したら今回作ったものだけを消す。source には触れない。
    for (const target of moved) {
      if (guard.exists(target)) guard.remove(target);
    }
    throw error;
  } finally {
    guard.remove(stage);
  }

  return {
    migratedEntries: registry.resources.length,
    skipped: stores.length - moved.length,
  };
}
