import { homedir } from "node:os";
import { basename } from "node:path";
import { AgentId, KindId, ScopeId } from "./agent";
import { AgentInfo, scanPath as detectAgents } from "./detector";
import { Env, Run } from "./env";
import { AgentToolError } from "./errors";
import { run as runCommand } from "./exec";
import { Candidate, discard, stage } from "./fetcher";
import { parseUrl, skillHint } from "./github";
import { install } from "./installer";
import { inventory as buildInventory, InventoryItem } from "./inventory";
import * as mcp from "./mcpScanner";
import { MCPScope, MCPServer } from "./mcpServer";
import { migrate as runMigration } from "./migration";
import { mcpStatus as pollMcpStatus } from "./processScanner";
import { cliOverrides, load, read, Registry, save, update } from "./registry";
import { disable, enable, remove as removeManaged, removeUnmanaged } from "./skillManager";
import { updateApply as applyUpdate, updatePreview as previewUpdate, UpdateDiff } from "./updater";

export { AgentToolError } from "./errors";
export type { ErrorCode } from "./errors";
export type { AgentInfo } from "./detector";
export type { InventoryItem } from "./inventory";
export type { UpdateDiff } from "./updater";
export type { MCPScope, MCPServer } from "./mcpServer";

export type Selector = {
  name: string;
  kind: KindId;
  scope: ScopeId;
  agent: AgentId;
  sourcePath?: string;
};

export type PreviewCandidate = {
  kind: KindId;
  name: string;
  installSelector?: string;
  description?: string;
};

/** `storagePath` は `context.globalStorageUri.fsPath`。OS 別パスは VS Code が解決する。 */
const envOf = (storagePath: string): Env => ({ home: homedir(), appSupport: storagePath });

/** 走査と操作で同じ実行系を使う。手動指定した CLI パスは registry が持つ。 */
const runnerFor = (env: Env): Run => {
  const overrides = cliOverrides(load(env));
  return command => {
    const [head, ...rest] = command;
    // `basename` で比べる。`endsWith("/" + head)` は Windows の `\` に当たらず、
    // 手動指定した CLI パスが黙って無視される。
    const manual = (Object.entries(overrides).find(([, path]) =>
      path !== undefined && head !== undefined && basename(path) === head) ?? [])[1];
    return runCommand(manual === undefined ? command : [manual, ...rest]);
  };
};

/** 壊れた registry の上で書き込みを始めない。read-modify-write はロックの中で行う。 */
async function mutate(storagePath: string,
                      change: (registry: Registry, env: Env) => void | Promise<void>): Promise<void> {
  const env = envOf(storagePath);
  read(env);                                     // 壊れていればここで落ちる
  await update(env, async registry => { await change(registry, env); });
}

export async function inventory(params: { storagePath: string; projectPath: string | null }):
  Promise<{ items: InventoryItem[]; issues: string[] }> {
  const env = envOf(params.storagePath);
  return buildInventory({ env, projectPath: params.projectPath, run: runnerFor(env) });
}

export function scanPath(params: { storagePath: string }): Promise<AgentInfo[]> {
  const env = envOf(params.storagePath);
  return detectAgents(env, runnerFor(env), cliOverrides(load(env)));
}

/** 取得した候補を返すだけ。入れるかどうかは確認画面で決める。 */
export async function preview(params: { url: string }): Promise<PreviewCandidate[]> {
  const source = parseUrl(params.url);
  if (source === null) {
    throw new AgentToolError("NOT_FOUND", "that URL is not a public GitHub repository");
  }
  const staging = await stage(source);
  try {
    const hint = skillHint(params.url);
    const candidates = hint === undefined ? staging.candidates
      : staging.candidates.filter(item => item.name === hint);
    return (candidates.length > 0 ? candidates : staging.candidates).map(toPreview);
  } finally {
    discard(staging);
  }
}

const toPreview = (candidate: Candidate): PreviewCandidate => ({
  kind: candidate.kind,
  name: candidate.name,
  installSelector: candidate.installSelector,
  description: candidate.description,
});

export async function add(params: {
  storagePath: string;
  url: string;
  kind: "skill" | "subagent" | "plugin";
  scope: ScopeId;
  name?: string;
}): Promise<void> {
  const source = parseUrl(params.url);
  if (source === null) {
    throw new AgentToolError("NOT_FOUND", "that URL is not a public GitHub repository");
  }
  const staging = await stage(source);
  try {
    const wanted = params.name ?? skillHint(params.url);
    const candidate = staging.candidates.find(item =>
      item.kind === params.kind && (wanted === undefined || item.name === wanted))
      ?? staging.candidates.find(item => item.kind === params.kind);
    if (candidate === undefined) {
      throw new AgentToolError("NOT_FOUND", `no ${params.kind} was found at that URL`);
    }
    await mutate(params.storagePath, (registry, env) => install(candidate, staging, env, registry));
  } finally {
    discard(staging);
  }
}

/**
 * 実体を触ってよい対象か。`skillManager.layout` は user スコープの置き場しか組まないので、
 * project スコープや Plugin を渡すと**同名の user スコープ実体**を消してしまう。
 * D-5 によりゴミ箱を経由しないため、取り違えは復旧できない。ここで先に落とす。
 *
 * ponytail: project スコープの実体管理は未実装。入れるなら `layout` に
 * `projectPath` を渡し、`.claude/skills` 直下だけを対象にする。
 */
export const isManageable = (selector: Selector): boolean =>
  selector.scope === "user" && (selector.kind === "skill" || selector.kind === "subagent");

function assertManageable(selector: Selector): void {
  if (isManageable(selector)) return;
  throw new AgentToolError("OPERATION_FAILED", selector.scope === "project"
    ? `${selector.name} belongs to this project; change it in the project files`
    : `${selector.kind} cannot be changed here`);
}

export async function remove(params: { storagePath: string; selector: Selector }): Promise<void> {
  assertManageable(params.selector);
  const { name, kind } = params.selector;
  return mutate(params.storagePath, (registry, env) => {
    // registry に載っていれば管理下の実体。載っていないものは他のツールが入れた資産で、
    // 既知ルート直下にある限り消せる（Mac App と同じ扱い）。
    const managed = registry.resources.some(item => item.name === name && item.kind === kind);
    if (managed) removeManaged(name, kind, env, registry);
    else removeUnmanaged(name, kind, env);
  });
}

export async function toggle(params: { storagePath: string; selector: Selector }):
  Promise<{ enabled: boolean }> {
  assertManageable(params.selector);
  const { name, kind } = params.selector;
  const env = envOf(params.storagePath);
  const wasEnabled = read(env).resources
    .find(item => item.name === name && item.kind === kind)?.disabled !== true;
  await mutate(params.storagePath, (registry, scoped) =>
    wasEnabled ? disable(name, kind, scoped, registry) : enable(name, kind, scoped, registry));
  return { enabled: !wasEnabled };
}

export function updatePreview(params: { storagePath: string; selector: Selector }): Promise<UpdateDiff> {
  const env = envOf(params.storagePath);
  return previewUpdate({ env, registry: read(env), name: params.selector.name, kind: params.selector.kind });
}

export async function updateApply(params: { storagePath: string; selector: Selector }):
  Promise<{ appliedSha: string }> {
  const env = envOf(params.storagePath);
  const registry = read(env);
  const result = await applyUpdate({ env, registry, name: params.selector.name, kind: params.selector.kind });
  return result;
}

/** 追加は user スコープだけ（`addCommand` が `-s user` を載せる）。 */
export function mcpAdd(params: {
  storagePath: string; agent: AgentId; server: MCPServer;
}): Promise<void> {
  const env = envOf(params.storagePath);
  return mcp.add(params.server, params.agent, env, runnerFor(env));
}

/** `scope` は CLI の `-s` にそのまま載る。取り違えると同名の user サーバーを消す。 */
export function mcpRemove(params: {
  storagePath: string; agent: AgentId; name: string; scope: MCPScope;
}): Promise<void> {
  const env = envOf(params.storagePath);
  return mcp.remove(params.name, params.agent, env, runnerFor(env), params.scope);
}

/** View 表示中に 3 秒ポーリングで呼ぶ。key は "agent:serverName"。 */
export async function mcpStatus(params: { storagePath: string }): Promise<Record<string, boolean>> {
  const env = envOf(params.storagePath);
  const runner = runnerFor(env);
  const { servers } = await mcp.scan(env, runner);
  return pollMcpStatus(servers, runner);
}

/**
 * Plugin の削除は各エージェントの CLI に委譲する。実体の置き場も削除方法も
 * エージェント側が持っていて、こちらの管理ストアには何も無い。
 * 同梱プラグインは消してもエージェントの更新で戻るので受け付けない。
 */
export async function pluginRemove(params: {
  storagePath: string; agent: AgentId; name: string; scope?: "user" | "project" | "local"; bundled?: boolean;
}): Promise<void> {
  if (params.agent !== "claude" && params.agent !== "codex") {
    throw new AgentToolError("OPERATION_FAILED", `${params.agent} does not support plugins`);
  }
  if (params.bundled === true) {
    throw new AgentToolError("WRITE_GUARD_DENIED",
      `${params.name} ships with ${params.agent} and would come back on the next update`);
  }
  const env = envOf(params.storagePath);
  await runnerFor(env)(pluginRemoveCommand(params.agent, params.name, params.scope ?? "user"));
}

/** Claude は Marketplace を先に登録する。Codex も同じ二段階だが `add` を使う。 */
export function pluginAddCommands(agent: "claude" | "codex", name: string, url?: string): string[][] {
  const install = agent === "claude"
    ? ["claude", "plugin", "install", name, "-s", "user"]
    : ["codex", "plugin", "add", name];
  return url === undefined ? [install] : [[agent, "plugin", "marketplace", "add", url], install];
}

/** Codex は scope を受けない。Claude は一覧が返した scope をそのまま使う。 */
export function pluginRemoveCommand(agent: "claude" | "codex", name: string,
                                    scope: "user" | "project" | "local"): string[] {
  return agent === "claude"
    ? ["claude", "plugin", "remove", name, "-s", scope]
    : ["codex", "plugin", "remove", name];
}

/** Plugin の追加は各エージェントの CLI に委譲する。 */
export async function pluginAdd(params: {
  storagePath: string; agent: AgentId; name: string; url?: string;
}): Promise<void> {
  if (params.agent !== "claude" && params.agent !== "codex") {
    throw new AgentToolError("OPERATION_FAILED", `${params.agent} does not support plugins`);
  }
  const env = envOf(params.storagePath);
  for (const argv of pluginAddCommands(params.agent, params.name, params.url)) await runnerFor(env)(argv);
}

export async function migrate(params: { storagePath: string; sourcePath: string }):
  Promise<{ migratedEntries: number; skipped: number }> {
  return runMigration(params.sourcePath, envOf(params.storagePath));
}

export { save, load };
