import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";

/** プロジェクト配下を歩く深さ。これ以上は掘らない。 */
export const SKILL_DEPTH = 3;
export const NOT_WALKED: ReadonlySet<string> =
  new Set(["node_modules", "Pods", "vendor", "target", "dist", "build", "out"]);

const isDirectory = (path: string): boolean => {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
};

/**
 * プロジェクト内の `.claude/skills` を探す。サブディレクトリは `SKILL_DEPTH` まで。
 * ホームやワークスペース全体は再帰走査しない（走査ホワイトリストの例外はここだけ）。
 */
export function projectSkillRoots(project: string): { prefix: string; path: string }[] {
  const found: { prefix: string; path: string }[] = [];
  walk(project, "", SKILL_DEPTH, found);
  return found;
}

function walk(dir: string, prefix: string, depth: number,
              found: { prefix: string; path: string }[]): void {
  const skills = join(dir, ".claude", "skills");
  if (isDirectory(skills)) found.push({ prefix, path: skills });
  if (depth <= 0) return;
  let children: string[];
  try {
    children = readdirSync(dir).filter(name => !name.startsWith(".") && !NOT_WALKED.has(name)).sort();
  } catch {
    return;
  }
  for (const child of children) {
    const path = join(dir, child);
    if (!isDirectory(path)) continue;
    walk(path, prefix === "" ? child : `${prefix}/${child}`, depth - 1, found);
  }
}

/** Subagent はプロジェクト直下だけ。走査もそこしか見ていない。 */
export const projectSubagentRoot = (project: string): string => join(project, ".claude", "agents");
