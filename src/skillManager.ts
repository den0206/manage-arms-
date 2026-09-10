import { join } from "node:path";
import { KindId } from "./agent";
import { agentStore, claudeSkills, disabledAgentStore, disabledStore, Env, skillStore } from "./env";
import { AgentToolError } from "./errors";
import { Entry, Registry, upsert } from "./registry";
import * as guard from "./writeGuard";

/**
 * 有効化・無効化・削除。
 *
 * 有効/無効は全エージェント一括。Cursor と Codex は `~/.agents/skills/` を直読みするので、
 * エージェント別の on/off は原理的に不可能。
 */
export type Layout = {
  /** 実体の置き場。 */
  readonly store: string;
  /** 無効化したときの退避先。実体は消さない。 */
  readonly parked: string;
  /** 各エージェントから見えるようにするリンク。 */
  readonly links: string[];
  /** リンクの種別。Skill はディレクトリ、Subagent は単一ファイル。 */
  readonly linkKind: "dir" | "file";
};

export function layout(name: string, kind: KindId, env: Env): Layout {
  // MCP と Plugin はこちらの管理ストアに実体を持たない。ここを素通りさせると
  // `~/.agents/skills/<name>` を指してしまい、同名の Skill を消しにいく。
  if (kind !== "skill" && kind !== "subagent") {
    throw new AgentToolError("OPERATION_FAILED",
      `${kind} is managed by the agent, not by Agent Tool`);
  }
  if (kind === "subagent") {
    return {
      store: join(agentStore(env), `${name}.md`),
      parked: join(disabledAgentStore(env), `${name}.md`),
      // Subagent は共有ルートの慣習が無いのでリンクが 2 本要る。
      links: [join(env.home, ".claude", "agents", `${name}.md`),
              join(env.home, ".cursor", "agents", `${name}.md`)],
      linkKind: "file",
    };
  }
  return {
    store: join(skillStore(env), name),
    parked: join(disabledStore(env), name),
    // Claude だけは共有ルートを読まないのでリンクが要る。Cursor / Codex は直読み。
    links: [join(claudeSkills(env), name)],
    linkKind: "dir",
  };
}

const notFound = (name: string): never => {
  throw new AgentToolError("NOT_FOUND", `${name} was not found`);
};

const rollbackFailed = (original: unknown, rollback: unknown): never => {
  throw new AgentToolError("OPERATION_FAILED",
    `the operation failed and the original state could not be fully restored: ${original}; ${rollback}`);
};

const entryFor = (registry: Registry, name: string, kind: KindId): Entry =>
  registry.resources.find(item => item.name === name && item.kind === kind)
  ?? { name, kind, pinned: false, disabled: false };

/** 実体へのリンクを張り直す。既に別のものがある位置は上書きしない。 */
export function link(name: string, kind: KindId, env: Env, registry: Registry): void {
  guard.assertValidName(name);
  const plan = layout(name, kind, env);

  const previous = new Map<string, string>();
  for (const path of plan.links) {
    if (!guard.isLink(path)) continue;
    guard.assertMutable(path, env, registry);
    const target = guard.linkTarget(path);
    if (target !== null) previous.set(path, target);
  }
  for (const path of plan.links) {
    if (!guard.isLink(path) && guard.exists(path) && !guard.isManagedLink(path, plan.store)) {
      throw new AgentToolError("ALREADY_EXISTS", `${path} already holds something else; not overwriting`);
    }
  }

  const changed: string[] = [];
  try {
    for (const path of plan.links) {
      guard.prepare(path, join(path, ".."), env.home);
      if (guard.exists(path) || guard.isLink(path)) guard.removeLink(path);
      guard.createLink(plan.store, path, plan.linkKind);
      changed.push(path);
    }
  } catch (error) {
    try {
      for (const path of changed) {
        if (guard.isManagedLink(path, plan.store)) guard.removeLink(path);
      }
      for (const [path, target] of previous) {
        if (!guard.exists(path)) guard.createLink(target, path, plan.linkKind);
      }
    } catch (rollback) {
      rollbackFailed(error, rollback);
    }
    throw error;
  }
}

/** 実体を置き場に戻し、リンクを張り直す。 */
export function enable(name: string, kind: KindId, env: Env, registry: Registry): void {
  guard.assertValidName(name);
  const plan = layout(name, kind, env);
  const wasParked = !guard.exists(plan.store);

  if (wasParked) {
    if (!guard.exists(plan.parked)) notFound(name);
    guard.assertMutable(plan.parked, env, registry);
    guard.prepare(plan.store, join(plan.store, ".."),
      guard.isInside(plan.store, env.home) ? env.home : env.appSupport);
    guard.move(plan.parked, plan.store);
  }
  try {
    link(name, kind, env, registry);
    upsert(registry, { ...entryFor(registry, name, kind), disabled: false });
  } catch (error) {
    try {
      for (const path of plan.links) {
        if (guard.isManagedLink(path, plan.store)) guard.removeLink(path);
      }
      if (wasParked && guard.exists(plan.store) && !guard.exists(plan.parked)) {
        guard.move(plan.store, plan.parked);
      }
    } catch (rollback) {
      rollbackFailed(error, rollback);
    }
    throw error;
  }
}

/**
 * リンクを外し、実体を退避ディレクトリへ移す。実体は消さない。
 *
 * 前提の検査を全部先に済ませてから壊す。破壊の順序は実体の退避 → リンクの解除。
 * 逆にすると、途中で失敗したときに「リンクが無いだけ」の見えない状態が残る。
 * この順なら残るのはリンク切れで、一覧が「読み込めません」として拾える。
 */
export function disable(name: string, kind: KindId, env: Env, registry: Registry): void {
  guard.assertValidName(name);
  const plan = layout(name, kind, env);

  if (!guard.exists(plan.store)) notFound(name);
  guard.assertMutable(plan.store, env, registry);
  if (guard.exists(plan.parked)) {
    throw new AgentToolError("ALREADY_EXISTS", `${plan.parked} already holds something else; not overwriting`);
  }
  const links = plan.links.filter(path => guard.isManagedLink(path, plan.store));
  for (const path of links) guard.assertMutable(path, env, registry);

  try {
    guard.prepare(plan.parked, join(plan.parked, ".."),
      guard.isInside(plan.parked, env.home) ? env.home : env.appSupport);
    guard.move(plan.store, plan.parked);
    for (const path of links) guard.removeLink(path);
    upsert(registry, { ...entryFor(registry, name, kind), disabled: true });
  } catch (error) {
    try {
      if (guard.exists(plan.parked) && !guard.exists(plan.store)) {
        guard.move(plan.parked, plan.store);
      }
      for (const path of links) {
        if (!guard.exists(path)) guard.createLink(plan.store, path, plan.linkKind);
      }
    } catch (rollback) {
      rollbackFailed(error, rollback);
    }
    throw error;
  }
}

/**
 * リンクと実体を消し、registry から外す。
 * ゴミ箱へは送らないので、呼び出し前に必ず確認ダイアログを出す（設計決定 D-5）。
 */
export function remove(name: string, kind: KindId, env: Env, registry: Registry): void {
  guard.assertValidName(name);
  const plan = layout(name, kind, env);

  // `disable` と同じ理由で、検査を全部先に済ませてから壊す。
  const links = plan.links.filter(path => guard.isManagedLink(path, plan.store) || guard.isLink(path));
  const bodies = [plan.store, plan.parked].filter(guard.exists);
  if (bodies.length === 0) notFound(name);
  for (const path of [...links, ...bodies]) guard.assertMutable(path, env, registry);

  for (const path of links) guard.removeLink(path);
  for (const path of bodies) guard.remove(path);
  registry.resources = registry.resources.filter(item => !(item.name === name && item.kind === kind));
}

/**
 * 他のツールが入れた実体を消す。registry に載っていないので `assertMutable` は通らない。
 * 代わりに「既知ルート直下にあること」だけを条件にする（`assertUserArtifact`）。
 *
 * 同じ名前が複数のルートに現れる（実体 + 各エージェントへのリンク）ので、
 * 走査ホワイトリストの全ルートを見て一括で消す。消した位置を返す。
 */
export function removeUnmanaged(name: string, kind: KindId, env: Env): string[] {
  guard.assertValidName(name);
  if (kind !== "skill" && kind !== "subagent") {
    throw new AgentToolError("OPERATION_FAILED",
      `${kind} is managed by the agent, not by Agent Tool`);
  }
  const leaf = kind === "subagent" ? `${name}.md` : name;
  // リンク切れは `exists` が false になるので、リンクかどうかも見る。
  const targets = guard.userRoots(kind, env)
    .map(root => join(root, leaf))
    .filter(path => guard.exists(path) || guard.isLink(path));
  if (targets.length === 0) notFound(name);

  // `disable` と同じ理由で、検査を全部先に済ませてから壊す。
  for (const path of targets) guard.assertUserArtifact(path, kind, env);
  for (const path of targets) guard.remove(path);
  return targets;
}
