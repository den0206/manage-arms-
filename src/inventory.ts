import { AgentId, AGENT_IDS, BUNDLED_SKILL_ROOTS, KindId, ScopeId, skillRoots, subagentRoots } from "./agent";
import { agentStore, disabledAgentStore, disabledStore, Env, Run, skillStore } from "./env";
import * as mcp from "./mcpScanner";
import { MCPScope, summary as mcpSummary } from "./mcpServer";
import * as plugins from "./pluginScanner";
import { projectSkillRoots, projectSubagentRoot } from "./projectScan";
import { Entry, load, Registry } from "./registry";
import { isLoadable, scanSkillRoot, scanSkills, scanSubagentRoot, scanSubagents, Skill } from "./skillScanner";

export type InventoryItem = {
  readonly name: string;
  readonly kind: KindId;
  readonly scope: ScopeId;
  /** 複数エージェントで共有する場合がある。 */
  readonly agents: AgentId[];
  readonly enabled: boolean;
  readonly origin: "managed" | "user" | "bundled";
  readonly sourcePath?: string;
  readonly repoUrl?: string;
  readonly hasUpdate: boolean;
  /** frontmatter の先頭 4 KB から取得。本文は詳細表示のときだけ読む。 */
  readonly summary?: string;
  /** MCP の登録先。削除コマンドの `-s` になるので `scope` に潰さず持つ。 */
  readonly mcpScope?: MCPScope;
  /** Plugin の登録先。Claude の削除コマンドの `-s` になる。 */
  readonly pluginScope?: "user" | "project" | "local";
};

/** 無効化して退避したものの擬似ルート。どのエージェントからも見えない。 */
export const PARKED = "(disabled)";

const byName = (a: InventoryItem, b: InventoryItem): number =>
  a.name < b.name ? -1 : a.name > b.name ? 1 : 0;

/** 更新の有無は registry.json だけで決まる。固定中は数えない。 */
export function hasUpdate(entry: Entry | undefined, registry: Registry): boolean {
  if (!entry || entry.pinned || !entry.repo) return false;
  const latest = registry.repos[`${entry.repo}#${entry.branch ?? "main"}`]?.latestSha;
  return latest !== undefined && latest !== entry.sha;
}

/**
 * スキルの出どころ。エージェント同梱ルートにしか無いものだけを bundled にする —
 * ユーザーが同名のものを自分の置き場にも持っていれば、それは自分のもの。
 */
function origin(name: string, kind: KindId, roots: string[], registry: Registry):
  InventoryItem["origin"] {
  const visible = roots.filter(root => root !== PARKED);
  if (visible.length > 0 && visible.every(root => BUNDLED_SKILL_ROOTS.has(root))) return "bundled";
  return registry.resources.some(e => e.name === name && e.kind === kind) ? "managed" : "user";
}

function group(found: Skill[], kind: KindId, scope: ScopeId, registry: Registry,
               rootsFor: (agent: AgentId) => string[]): InventoryItem[] {
  const groups = new Map<string, Skill[]>();
  for (const item of found) groups.set(item.name, [...(groups.get(item.name) ?? []), item]);

  return [...groups].map(([name, items]) => {
    // リンク切れ・SKILL.md 欠落は「有効」にしない。退避中はどこからも見えない。
    const visible = new Set(items.filter(item => isLoadable(item.status) && item.root !== PARKED)
      .map(item => item.root));
    const entry = registry.resources.find(e => e.name === name && e.kind === kind);
    return {
      name, kind, scope,
      agents: AGENT_IDS.filter(agent => rootsFor(agent).some(root => visible.has(root))),
      enabled: !items.some(item => item.root === PARKED),
      origin: origin(name, kind, items.map(item => item.root), registry),
      sourcePath: items[0].path,
      repoUrl: entry?.repo,
      hasUpdate: hasUpdate(entry, registry),
      summary: items.find(item => item.description !== undefined)?.description,
    };
  }).sort(byName);
}

function userSkills(env: Env, registry: Registry): InventoryItem[] {
  // 無効化したスキルは走査ルートから消えるので、退避先も併せて読む。
  // これが無いと再有効化する手段がなくなる。
  const found = [...scanSkills(env), ...scanSkillRoot(disabledStore(env), PARKED)];
  return group(found, "skill", "user", registry, skillRoots);
}

function userSubagents(env: Env, registry: Registry): InventoryItem[] {
  const found = [...scanSubagents(env), ...scanSubagentRoot(disabledAgentStore(env), PARKED)];
  return group(found, "subagent", "user", registry, subagentRoots);
}

/** プロジェクトのスキルとサブエージェント。ユーザー資産なので origin は user のまま。 */
function projectItems(project: string, registry: Registry): InventoryItem[] {
  // ルート名はユーザー側と同じ `.claude/skills` にする。どのエージェントが読むかは
  // `skillRoots` の宣言だけで決まり、サブディレクトリの位置では変わらない。
  const skills = projectSkillRoots(project).flatMap(({ prefix, path }) =>
    // サブディレクトリのスキルは `apps/web:deploy` として区別する。
    // 名前で畳むので、修飾しないと別物が 1 行に潰れる。
    scanSkillRoot(path, ".claude/skills")
      .map(skill => prefix === "" ? skill : { ...skill, name: `${prefix}:${skill.name}` }));
  const subagents = scanSubagentRoot(projectSubagentRoot(project), ".claude/agents");
  return [
    ...group(skills, "skill", "project", registry, skillRoots),
    ...group(subagents, "subagent", "project", registry, subagentRoots),
  ];
}

export async function inventory(params: {
  env: Env; projectPath: string | null; run?: Run; user?: boolean;
}): Promise<{ items: InventoryItem[]; issues: string[] }> {
  const { env, projectPath, run } = params;
  const includeUser = params.user !== false;
  const registry = load(env);
  const issues: string[] = [];

  let mcpItems: InventoryItem[] = [];
  if (includeUser) {
    const servers = await mcp.scan(env, run);
    issues.push(...servers.issues);
    mcpItems = AGENT_IDS.flatMap(agent =>
      (servers.servers[agent] ?? []).map(server => ({
        name: server.name, kind: "mcp" as const, scope: "user" as const, agents: [agent],
        enabled: server.enabled,
        origin: server.isProtected ? "bundled" as const : "user" as const,
        hasUpdate: false, summary: mcpSummary(server), mcpScope: "user" as const,
      }))).sort(byName);
  }

  const installed = await plugins.scan(env, run);
  issues.push(...installed.issues);
  // CLI は全プロジェクトの Plugin を返す。今見ている projectPath 以外は載せない。
  const pluginItems: InventoryItem[] = installed.plugins
    .filter(plugin => plugin.projectPath === projectPath
      || (includeUser && plugin.projectPath === undefined))
    .map((plugin): InventoryItem => ({
      name: plugin.id, kind: "plugin", scope: plugin.projectPath ? "project" : "user",
      agents: [plugin.agent], enabled: plugin.enabled,
      origin: plugin.isBundled ? "bundled" : "user",
      sourcePath: plugin.projectPath, hasUpdate: false,
      pluginScope: plugin.scope,
      summary: plugin.version === undefined ? undefined : `v${plugin.version}`,
    })).sort(byName);

  const projectItemList = projectPath === null ? [] : projectItems(projectPath, registry);
  const projectMcp: InventoryItem[] = projectPath === null ? []
    : [...mcp.readProject(projectPath, env)].map(([name, { server, scope }]): InventoryItem => ({
      name, kind: "mcp", scope: "project", agents: ["claude" as AgentId],
      enabled: server.enabled, origin: server.isProtected ? "bundled" : "user",
      hasUpdate: false, summary: `${scope} · ${mcpSummary(server)}`, mcpScope: scope,
    }));

  return {
    items: [
      ...(includeUser ? [...userSkills(env, registry), ...userSubagents(env, registry), ...mcpItems] : []),
      ...pluginItems, ...projectItemList, ...projectMcp,
    ],
    issues,
  };
}
