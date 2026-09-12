import { AgentId, configDir, skillRoots, subagentRoots, supports } from "./agent.js";
import { DetectKind } from "./detect.js";

/**
 * ブラウザ拡張の導入先。ホーム相対のルートと、その下に作る名前だけを決める。
 * 絶対パスは持てない — File System Access API のハンドルからは basename しか得られない。
 */
export type Placement = {
  /** 利用者に選んでもらうルート（ホーム相対）。 */
  readonly root: string;
  /** ルート直下に作るもの。Skill はディレクトリ、Subagent は `.md` ファイル。 */
  readonly entry: string;
  readonly isDirectory: boolean;
};

/** Cursor と Codex はどちらもここを読む。1 つ置けば両方から使える。 */
export const SHARED_SKILL_ROOT = ".agents/skills";

/** その種別を導入できるエージェント。Gemini は MCP だけなので現れない。 */
export const targets = (kind: DetectKind): AgentId[] =>
  (["claude", "cursor", "codex", "gemini"] as const)
    .filter(agent => supports(agent, kind) && roots(agent, kind).length > 0);

const roots = (agent: AgentId, kind: DetectKind): string[] =>
  kind === "skill" ? skillRoots(agent) : subagentRoots(agent);

/**
 * 置き場を決める。共有ストアを読むエージェントで、かつ利用者が共有ストアを許可済みなら
 * そこへ 1 つ置く。読まないエージェント（Claude）と未許可のときは各エージェント直下へ。
 */
export function placement(
  agent: AgentId, kind: DetectKind, name: string,
  sharedRootAvailable: boolean,
): Placement | null {
  if (!supports(agent, kind)) return null;
  const available = roots(agent, kind);
  if (available.length === 0) return null;

  const root = sharedRootAvailable && available.includes(SHARED_SKILL_ROOT)
    ? SHARED_SKILL_ROOT
    : `${configDir(agent)}/${kind === "skill" ? "skills" : "agents"}`;
  // 選んだルートがそのエージェントの読む場所に入っていること。推測で書かない。
  if (!available.includes(root)) return null;

  return kind === "skill"
    ? { root, entry: name, isDirectory: true }
    : { root, entry: `${name}.md`, isDirectory: false };
}
